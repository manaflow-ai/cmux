import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Parses a Swift view expression with `swift-syntax` and interprets the
/// currently supported subset into a ``RenderNode`` tree.
///
/// Phase 1 scope: SwiftUI constructor calls (`Text`, `VStack`, `HStack`,
/// `ZStack`, `Button`, `Spacer`, `Divider`), trailing-closure bodies, the
/// `spacing:` argument, string literals with interpolation, modifier chains
/// (recorded as ``RenderModifier``), and inside a ViewBuilder body the
/// language constructs `for … in <range>`, `if/else`, and `let` bindings,
/// evaluated against an ``EvalEnvironment`` seeded with `@State`-style values.
/// Unsupported syntax is skipped rather than crashing.
///
/// ```swift
/// let node = SwiftViewInterpreter().evaluate("""
/// VStack(spacing: 8) {
///     let title = "Items"
///     Text(title).font(.headline)
///     for i in 0..<3 {
///         if i > 0 { Divider() }
///         Text("Row \\(i)")
///     }
/// }
/// """, state: ["count": .int(2)])
/// ```
public struct SwiftViewInterpreter: Sendable {
    private let expressions = ExpressionEvaluator()

    public init() {}

    /// Parses `source` into a reusable ``ParsedProgram``.
    ///
    /// This is the expensive, source-only step (lexing, parsing, operator
    /// folding). Cache the result and feed it to ``evaluate(_:state:)`` when
    /// only the live data changes, so a host that re-renders on a timer does
    /// not re-parse unchanged source every frame.
    ///
    /// Runs on a dedicated large-stack worker thread: `swift-syntax`'s
    /// recursive-descent parse recurses with source nesting and untrusted
    /// authored sidebars can nest arbitrarily deep, so a 16 MB stack absorbs
    /// realistic depth without overflowing the (small) caller stack.
    public func parse(_ source: String) -> ParsedProgram {
        onLargeStack {
            let parsed = Parser.parse(source: source)
            let file = (try? OperatorTable.standardOperators.foldAll(parsed))?
                .as(SourceFileSyntax.self) ?? parsed
            return ParsedProgram(file: file)
        }
    }

    /// Interprets an already-parsed ``ParsedProgram``'s first top-level
    /// expression against an environment seeded with `state`. Returns `nil`
    /// when nothing supported is found.
    ///
    /// Runs the tree-walk on a dedicated large-stack worker thread (the walker
    /// recurses with view nesting); the per-``EvalEnvironment`` ``RecursionBudget``
    /// backstops genuinely unbounded interpreter recursion (e.g. mutually
    /// recursive view helpers).
    public func evaluate(_ program: ParsedProgram, state: [String: SwiftValue] = [:]) -> RenderNode? {
        onLargeStack {
            let env = EvalEnvironment(values: state)
            self.registerFunctions(program.file.statements, env)
            for item in program.file.statements {
                if let expr = item.item.as(ExprSyntax.self), let node = self.evalView(expr, env) {
                    // A tripped node budget means the tree was truncated
                    // mid-walk; publish nothing so the host's last-good-sticky
                    // render keeps the previous output instead of flashing a
                    // partial tree.
                    return env.budget.nodesExceeded ? nil : node
                }
            }
            return nil
        }
    }

    /// Parses `source` and interprets the first top-level expression against
    /// an environment seeded with `state`. Returns `nil` when nothing
    /// supported is found.
    ///
    /// Convenience for one-shot evaluation; when re-rendering against changing
    /// data, call ``parse(_:)`` once and reuse the ``ParsedProgram``.
    public func evaluate(_ source: String, state: [String: SwiftValue] = [:]) -> RenderNode? {
        evaluate(parse(source), state: state)
    }

    /// Runs `work` on a dedicated 16 MB-stack worker thread and returns its
    /// result, so deep recursive-descent parsing and tree-walking do not
    /// overflow the (small) caller stack.
    private func onLargeStack<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T {
        // `box` is written once on the worker and read only after the join
        // signal below, so the unchecked Sendable is safe.
        let box = LargeStackResultBox<T>()
        let done = DispatchSemaphore(value: 0) // one-shot thread-join signal, not a state lock.
        let worker = Thread {
            box.value = work()
            done.signal()
        }
        worker.stackSize = 16 * 1024 * 1024
        worker.start()
        done.wait()
        return box.value!
    }

    /// Registers any `func` declarations in `items` into `env` so value and
    /// view helpers can be called (including before their declaration).
    private func registerFunctions(_ items: CodeBlockItemListSyntax, _ env: EvalEnvironment) {
        for item in items {
            if let fn = item.item.as(FunctionDeclSyntax.self) {
                env.defineFunction(fn.name.text, fn)
            }
        }
    }

    private func bindParameters(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> EvalEnvironment {
        expressions.bindParameters(decl, call, env)
    }

    // MARK: - View expressions

    private func evalView(_ expr: ExprSyntax, _ env: EvalEnvironment) -> RenderNode? {
        env.budget.enter()
        defer { env.budget.leave() }
        guard !env.budget.exceeded, !env.budget.nodesExceeded else { return nil }
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        return evalCall(call, env)
    }

    private func evalCall(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> RenderNode? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base, var node = evalView(base, env) else { return nil }
            let name = member.declName.baseName.text
            // `.onTapGesture { … }` makes any view tappable; capture its
            // closure as the node's action so rich rows can run commands.
            if name == "onTapGesture", let closure = call.trailingClosure {
                node.action = parseAction(closure, env)
                return node
            }
            // Child-bearing modifiers carry their trailing closure's views as a
            // subtree (`.overlay { ... }`, `.background { ... }`, `.mask { ... }`,
            // `.safeAreaInset(edge:) { ... }`), so arbitrary nested content
            // composes, not just colors.
            let childBearing: Set<String> = ["overlay", "background", "mask", "safeAreaInset", "contextMenu"]
            if childBearing.contains(name), let closure = call.trailingClosure {
                node.modifiers.append(RenderModifier(
                    name: name,
                    args: modifierArgs(call.arguments, env),
                    children: evalItems(closure.statements, env)
                ))
                return node
            }
            node.modifiers.append(RenderModifier(name: name, args: modifierArgs(call.arguments, env)))
            return node
        }

        guard let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return nil }
        switch ref.baseName.text {
        case "Text":
            return RenderNode(kind: .text, text: stringArgument(call.arguments, env) ?? "")
        case "Button":
            // Label form: `Button(action: { … }) { labelView }` — the action
            // is the `action:` closure and the trailing closure is a rich
            // label rendered as the button's children.
            if let actionClosure = call.arguments
                .first(where: { $0.label?.text == "action" })?
                .expression.as(ClosureExprSyntax.self) {
                return RenderNode(
                    kind: .button,
                    children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [],
                    action: parseAction(actionClosure, env)
                )
            }
            // Title form: `Button("title") { action }`.
            return RenderNode(
                kind: .button,
                text: stringArgument(call.arguments, env) ?? "",
                action: call.trailingClosure.map { parseAction($0, env) }
            )
        case "Image":
            let name = call.arguments.first(where: { $0.label?.text == "systemName" })?.expression
                ?? call.arguments.first?.expression
            return RenderNode(kind: .image, systemName: name.flatMap { exprString($0, env) })
        case "Label":
            return RenderNode(
                kind: .label,
                text: stringArgument(call.arguments, env) ?? labeledStringArgument("title", call.arguments, env) ?? "",
                systemName: labeledStringArgument("systemImage", call.arguments, env)
            )
        case "Spacer":
            return RenderNode(kind: .spacer)
        case "Divider":
            return RenderNode(kind: .divider)
        case "Rectangle":
            return RenderNode(kind: .rectangle)
        case "Capsule":
            return RenderNode(kind: .capsule)
        case "Circle":
            return RenderNode(kind: .circle)
        case "Ellipse":
            return RenderNode(kind: .ellipse)
        case "UnevenRoundedRectangle":
            return RenderNode(kind: .unevenRoundedRectangle, cornerRadius: doubleArgument(named: "cornerRadius", call.arguments, env)
                ?? doubleArgument(named: "topLeadingRadius", call.arguments, env))
        case "RoundedRectangle":
            return RenderNode(kind: .roundedRectangle, cornerRadius: doubleArgument(named: "cornerRadius", call.arguments, env))
        case "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack":
            let kind: RenderNode.Kind
            switch ref.baseName.text {
            case "VStack": kind = .vstack
            case "HStack": kind = .hstack
            case "ZStack": kind = .zstack
            case "LazyVStack": kind = .lazyVStack
            default: kind = .lazyHStack
            }
            let children = call.trailingClosure.map { evalItems($0.statements, env) } ?? []
            return RenderNode(kind: kind, spacing: doubleArgument(named: "spacing", call.arguments, env), children: children)
        case "LinearGradient":
            return RenderNode(kind: .linearGradient, colors: gradientColors(call, env),
                              points: [gradientUnitPoint("startPoint", call), gradientUnitPoint("endPoint", call)])
        case "RadialGradient":
            return RenderNode(kind: .radialGradient, colors: gradientColors(call, env),
                              points: [gradientUnitPoint("center", call)])
        case "AngularGradient":
            return RenderNode(kind: .angularGradient, colors: gradientColors(call, env),
                              points: [gradientUnitPoint("center", call)])
        case "AnyView":
            // Type-erasure wrapper: render the wrapped view.
            if let inner = call.arguments.first(where: { $0.label == nil })?.expression {
                return evalView(inner, env)
            }
            return call.trailingClosure.flatMap { evalItems($0.statements, env).first }
        case "Group":
            return RenderNode(kind: .group, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "EmptyView":
            return RenderNode(kind: .group)
        case "List":
            return RenderNode(kind: .list, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "Section":
            // `Section("Header") { ... }` / `Section { ... }`: the leading
            // string literal (if any) becomes the header above the content.
            return RenderNode(
                kind: .section,
                text: stringArgument(call.arguments, env),
                children: call.trailingClosure.map { evalItems($0.statements, env) } ?? []
            )
        case "Grid":
            return RenderNode(kind: .grid, spacing: doubleArgument(named: "spacing", call.arguments, env),
                              children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "GridRow":
            return RenderNode(kind: .gridRow, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "LazyVGrid":
            return RenderNode(kind: .lazyVGrid, spacing: doubleArgument(named: "spacing", call.arguments, env),
                              children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "LazyHGrid":
            return RenderNode(kind: .lazyHGrid, spacing: doubleArgument(named: "spacing", call.arguments, env),
                              children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "ViewThatFits":
            return RenderNode(kind: .viewThatFits, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "ProgressView":
            return RenderNode(
                kind: .progressView,
                text: stringArgument(call.arguments, env),
                value: progressValue(call, env)
            )
        case "Gauge":
            return RenderNode(
                kind: .gauge,
                text: labeledStringArgument("label", call.arguments, env) ?? stringArgument(call.arguments, env),
                // Same total-relative normalization as ProgressView: the
                // rendered Gauge(value:) is 0...1.
                value: progressValue(call, env)
            )
        case "Menu":
            return RenderNode(
                kind: .menu,
                text: stringArgument(call.arguments, env) ?? labeledStringArgument("title", call.arguments, env) ?? "",
                children: call.trailingClosure.map { evalItems($0.statements, env) } ?? []
            )
        case "HSplitView":
            return RenderNode(kind: .hsplit, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "ScrollView":
            let children = call.trailingClosure.map { evalItems($0.statements, env) } ?? []
            // A horizontal scroll view nests usefully inside the vertically
            // scrolling sidebar; a vertical one would double-scroll, so it stays
            // a passthrough vertical container.
            if scrollViewIsHorizontal(call, env) {
                return RenderNode(kind: .hscroll, children: children)
            }
            return RenderNode(kind: .vstack, children: children)
        case "Reorderable":
            return evalReorderable(call, env)
        default:
            // A user-defined view helper: `func row(x) -> some View { ... }`
            // called in view position; evaluate its body as view items.
            if let decl = env.lookupFunction(ref.baseName.text), let body = decl.body {
                let scope = bindParameters(decl, call, env)
                let nodes = evalItems(body.statements, scope)
                if nodes.count == 1 { return nodes[0] }
                return RenderNode(kind: .vstack, children: nodes)
            }
            return nil
        }
    }

    // MARK: - ViewBuilder statements

    private func evalItems(_ items: CodeBlockItemListSyntax, _ env: EvalEnvironment) -> [RenderNode] {
        env.budget.enter()
        defer { env.budget.leave() }
        guard !env.budget.exceeded, !env.budget.nodesExceeded else { return [] }
        registerFunctions(items, env)
        var out: [RenderNode] = []
        for item in items {
            // Stop producing once the node budget trips; the top-level
            // evaluate discards the truncated walk.
            if env.budget.nodesExceeded { break }
            let node = item.item
            if let decl = node.as(VariableDeclSyntax.self) {
                applyBinding(decl, env)
            } else if let loop = node.as(ForStmtSyntax.self) {
                out += evalFor(loop, env)
            } else if let ifExpr = ifExpression(node) {
                out += evalIf(ifExpr, env)
            } else if let switchExpr = switchExpression(node) {
                out += evalSwitch(switchExpr, env)
            } else if let ret = node.as(ReturnStmtSyntax.self), let expr = ret.expression {
                // A view helper with an explicit `return SomeView` (or
                // `return ForEach(...) { }`) renders its returned expression,
                // not nothing.
                if let call = expr.as(FunctionCallExprSyntax.self), isForEach(call) {
                    out += evalForEach(call, env)
                } else if let child = evalView(expr, env) {
                    env.budget.recordNode()
                    out.append(child)
                }
            } else if let expr = node.as(ExprSyntax.self) {
                if let call = expr.as(FunctionCallExprSyntax.self), isForEach(call) {
                    out += evalForEach(call, env)
                } else if let child = evalView(expr, env) {
                    env.budget.recordNode()
                    out.append(child)
                }
            }
        }
        return out
    }

    /// Extracts an `if` from a code-block item, whether it appears directly
    /// as an expression (`if`-expression) or wrapped in an
    /// `ExpressionStmtSyntax` (the usual ViewBuilder statement form).
    private func ifExpression(_ node: CodeBlockItemSyntax.Item) -> IfExprSyntax? {
        if let ifExpr = node.as(IfExprSyntax.self) { return ifExpr }
        if let stmt = node.as(ExpressionStmtSyntax.self) { return stmt.expression.as(IfExprSyntax.self) }
        if let expr = node.as(ExprSyntax.self) { return expr.as(IfExprSyntax.self) }
        return nil
    }

    /// Extracts gradient color stops from a `colors: [...]` argument, or from a
    /// nested `gradient: Gradient(colors: [...])`. Each stop is a hex/token
    /// string the bridge resolves via the color palette.
    private func gradientColors(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> [String] {
        var arrayExpr = call.arguments.first(where: { $0.label?.text == "colors" })?.expression
        if arrayExpr == nil,
           let gradient = call.arguments.first(where: { $0.label?.text == "gradient" })?.expression.as(FunctionCallExprSyntax.self) {
            arrayExpr = gradient.arguments.first(where: { $0.label?.text == "colors" })?.expression
        }
        guard let array = arrayExpr?.as(ArrayExprSyntax.self) else { return [] }
        return array.elements.map { element in
            if let literal = element.expression.as(StringLiteralExprSyntax.self) {
                return expressions.evalString(literal, env)
            }
            if let member = element.expression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text // `.red` -> "red"
            }
            return exprString(element.expression, env) ?? element.expression.trimmedDescription
        }
    }

    /// A gradient `UnitPoint` argument as a bare token (`.top` -> "top").
    private func gradientUnitPoint(_ label: String, _ call: FunctionCallExprSyntax) -> String {
        guard let expr = call.arguments.first(where: { $0.label?.text == label })?.expression else { return "" }
        if let member = expr.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return expr.trimmedDescription
    }

    /// Normalized `ProgressView` fraction (0...1) from `value:`/`total:`, or nil
    /// for the indeterminate form.
    private func progressValue(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> Double? {
        guard let value = doubleArgument(named: "value", call.arguments, env) else { return nil }
        let total = doubleArgument(named: "total", call.arguments, env) ?? 1
        guard total != 0 else { return nil }
        return max(0, min(1, value / total))
    }

    /// Whether a `ScrollView(...)` declares a horizontal axis. Inspects the
    /// leading unlabeled `axes` argument's source for `.horizontal`.
    private func scrollViewIsHorizontal(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> Bool {
        guard let axes = call.arguments.first(where: { $0.label == nil })?.expression else { return false }
        return axes.trimmedDescription.contains("horizontal")
    }

    /// Evaluates `Reorderable(data, move: "method", id: "field") { item in row }`
    /// into a `.reorderable` node: one rendered row per item plus a
    /// ``ReorderSpec`` carrying the item ids and the drop command.
    private func evalReorderable(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> RenderNode? {
        guard let dataExpr = call.arguments.first(where: { $0.label == nil })?.expression,
              case let .array(items)? = expressions.eval(dataExpr, env),
              let closure = call.trailingClosure else { return nil }
        let method = labeledStringArgument("move", call.arguments, env) ?? "workspace.reorder"
        let idField = labeledStringArgument("id", call.arguments, env) ?? "id"
        let idParam = labeledStringArgument("idParam", call.arguments, env) ?? "workspace_id"
        let indexParam = labeledStringArgument("indexParam", call.arguments, env) ?? "index"
        let paramName = closureParameterNames(closure).first

        var rows: [RenderNode] = []
        var ids: [String] = []
        for item in items {
            let scope = env.makeChild()
            if let paramName { scope.define(paramName, item) }
            scope.define("$0", item)
            let rowNodes = evalItems(closure.statements, scope)
            rows.append(rowNodes.count == 1 ? rowNodes[0] : RenderNode(kind: .vstack, children: rowNodes))
            ids.append(item.member(idField)?.displayString ?? "")
        }
        return RenderNode(
            kind: .reorderable,
            children: rows,
            reorder: ReorderSpec(method: method, idParam: idParam, indexParam: indexParam, itemIds: ids)
        )
    }

    private func labeledStringArgument(_ label: String, _ args: LabeledExprListSyntax, _ env: EvalEnvironment) -> String? {
        guard let expr = args.first(where: { $0.label?.text == label })?.expression else { return nil }
        return exprString(expr, env)
    }

    private func isForEach(_ call: FunctionCallExprSyntax) -> Bool {
        call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "ForEach"
    }

    /// Expands `ForEach(<sequence>) { item in … }` into a flat list of nodes,
    /// binding the closure parameter (or `$0`) to each element.
    private func evalForEach(_ call: FunctionCallExprSyntax, _ env: EvalEnvironment) -> [RenderNode] {
        guard let sequenceExpr = call.arguments.first?.expression,
              let sequence = expressions.eval(sequenceExpr, env),
              let values = sequence.iterationValues,
              let closure = call.trailingClosure else { return [] }
        let names = closureParameterNames(closure)
        var out: [RenderNode] = []
        for value in values {
            // A pathological sequence (e.g. `ForEach(0..<100_000)`) must trip
            // the node budget after a few thousand rows, not iterate to the
            // end doing wasted work.
            if env.budget.nodesExceeded { break }
            let scope = env.makeChild()
            if names.count >= 2 {
                // Two-param form, e.g. `ForEach(Array(xs.enumerated()), id: \.offset)
                // { index, item in }`: destructure the pair's "0"/"1" members.
                scope.define(names[0], value.member("0") ?? value)
                scope.define(names[1], value.member("1") ?? value)
                scope.define("$0", value.member("0") ?? value)
                scope.define("$1", value.member("1") ?? value)
            } else {
                if let name = names.first { scope.define(name, value) }
                scope.define("$0", value)
            }
            out += evalItems(closure.statements, scope)
        }
        return out
    }

    private func closureParameterNames(_ closure: ClosureExprSyntax) -> [String] {
        guard let parameterClause = closure.signature?.parameterClause else { return [] }
        if case let .simpleInput(list) = parameterClause {
            return list.map { $0.name.text }
        }
        if case let .parameterClause(clause) = parameterClause {
            return clause.parameters.map { $0.firstName.text }
        }
        return []
    }

    /// Captures the commands in a `Button` action closure (currently
    /// `cmux("method", args…)` calls), evaluating argument expressions
    /// against `env` so loop-captured values are baked in.
    private func parseAction(_ closure: ClosureExprSyntax, _ env: EvalEnvironment) -> ButtonAction {
        var commands: [ActionCommand] = []
        for item in closure.statements {
            guard let call = item.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self),
                  let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            else { continue }
            func value(_ arg: LabeledExprSyntax) -> String {
                expressions.eval(arg.expression, env)?.displayString ?? arg.expression.trimmedDescription
            }
            switch name {
            case "cmux":
                var method: String?
                var params: [String: String] = [:]
                for arg in call.arguments {
                    if let label = arg.label?.text {
                        params[label] = value(arg)
                    } else if method == nil {
                        method = value(arg)
                    }
                }
                if let method {
                    commands.append(.cmux(method: method, params: params))
                }
            case "log" where !call.arguments.isEmpty:
                commands.append(.log(value(call.arguments.first!)))
            case "openURL" where !call.arguments.isEmpty:
                commands.append(.openURL(value(call.arguments.first!)))
            default:
                continue
            }
        }
        return ButtonAction(commands: commands)
    }

    /// Extracts a `switch` from a code-block item (bare or wrapped in an
    /// `ExpressionStmtSyntax`).
    private func switchExpression(_ node: CodeBlockItemSyntax.Item) -> SwitchExprSyntax? {
        if let s = node.as(SwitchExprSyntax.self) { return s }
        if let stmt = node.as(ExpressionStmtSyntax.self) { return stmt.expression.as(SwitchExprSyntax.self) }
        if let expr = node.as(ExprSyntax.self) { return expr.as(SwitchExprSyntax.self) }
        return nil
    }

    /// Evaluates a view-position `switch`: the first matching (or `default`)
    /// case's statements are rendered.
    private func evalSwitch(_ switchExpr: SwitchExprSyntax, _ env: EvalEnvironment) -> [RenderNode] {
        let subject = expressions.eval(switchExpr.subject, env)
        for caseSyntax in switchExpr.cases {
            guard let switchCase = caseSyntax.as(SwitchCaseSyntax.self) else { continue }
            if switchCaseMatches(switchCase.label, subject, env) {
                return evalItems(switchCase.statements, env.makeChild())
            }
        }
        return []
    }

    /// Whether a `switch` case label matches `subject` (literal/`.member`
    /// patterns; `default` always matches).
    private func switchCaseMatches(_ label: SwitchCaseSyntax.Label, _ subject: SwiftValue?, _ env: EvalEnvironment) -> Bool {
        switch label {
        case .default:
            return true
        case let .case(caseLabel):
            for item in caseLabel.caseItems {
                if let pattern = item.pattern.as(ExpressionPatternSyntax.self) {
                    if let member = pattern.expression.as(MemberAccessExprSyntax.self), member.base == nil,
                       case let .string(value)? = subject, member.declName.baseName.text == value {
                        return true // `.running` matches subject string "running"
                    }
                    if expressions.eval(pattern.expression, env) == subject { return true }
                }
            }
            return false
        }
    }

    private func evalFor(_ loop: ForStmtSyntax, _ env: EvalEnvironment) -> [RenderNode] {
        guard let name = loop.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let sequence = expressions.eval(loop.sequence, env),
              let values = sequence.iterationValues else { return [] }
        var out: [RenderNode] = []
        for value in values {
            if env.budget.nodesExceeded { break } // same early-out as evalForEach
            let scope = env.makeChild()
            scope.define(name, value)
            out += evalItems(loop.body.statements, scope)
        }
        return out
    }

    private func evalIf(_ ifExpr: IfExprSyntax, _ env: EvalEnvironment) -> [RenderNode] {
        // The then-branch runs in a child scope so `if let x = …` bindings are
        // visible to it.
        let scope = env.makeChild()
        if conditionsPass(ifExpr.conditions, scope) {
            return evalItems(ifExpr.body.statements, scope)
        }
        guard let elseBody = ifExpr.elseBody else { return [] }
        if let block = elseBody.as(CodeBlockSyntax.self) {
            return evalItems(block.statements, env.makeChild())
        }
        if let elseIf = elseBody.as(IfExprSyntax.self) {
            return evalIf(elseIf, env)
        }
        return []
    }

    /// Evaluates an `if`/`guard` condition list against `scope`, binding any
    /// `let name = expr` (or shorthand `let name`) optional bindings into
    /// `scope` when non-nil. Returns false if any condition fails.
    private func conditionsPass(_ conditions: ConditionElementListSyntax, _ scope: EvalEnvironment) -> Bool {
        for element in conditions {
            if let binding = element.condition.as(OptionalBindingConditionSyntax.self) {
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                let resolved: SwiftValue?
                if let initializer = binding.initializer?.value {
                    resolved = expressions.eval(initializer, scope)
                } else if let name {
                    resolved = scope.lookup(name) // shorthand `if let name`
                } else {
                    resolved = nil
                }
                guard let value = resolved else { return false }
                if let name { scope.define(name, value) }
            } else if let expr = element.condition.as(ExprSyntax.self) {
                if !(expressions.eval(expr, scope)?.isTruthy ?? false) { return false }
            } else {
                return false
            }
        }
        return true
    }

    private func applyBinding(_ decl: VariableDeclSyntax, _ env: EvalEnvironment) {
        for binding in decl.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let value = binding.initializer.map({ expressions.eval($0.value, env) }) ?? nil else { continue }
            env.define(name, value)
        }
    }

    // MARK: - Argument helpers

    private func stringArgument(_ args: LabeledExprListSyntax, _ env: EvalEnvironment) -> String? {
        guard let first = args.first?.expression else { return nil }
        return exprString(first, env)
    }

    /// Resolves an expression to a string: literal segments (with
    /// interpolation) or any value's display form.
    private func exprString(_ expr: ExprSyntax, _ env: EvalEnvironment) -> String? {
        if let literal = expr.as(StringLiteralExprSyntax.self) {
            return expressions.evalString(literal, env)
        }
        return expressions.eval(expr, env)?.displayString
    }

    private func doubleArgument(named label: String, _ args: LabeledExprListSyntax, _ env: EvalEnvironment) -> Double? {
        for arg in args where arg.label?.text == label {
            switch expressions.eval(arg.expression, env) {
            case let .int(value): return Double(value)
            case let .double(value): return value
            default: return nil
            }
        }
        return nil
    }

    /// Captures a modifier's labeled arguments, evaluating each to a string
    /// where possible (else the source token, e.g. `.infinity` / `.leading`).
    private func modifierArgs(_ args: LabeledExprListSyntax, _ env: EvalEnvironment) -> [ModifierArg] {
        args.map { arg in
            // Resolve a ternary to its taken branch first, so member-token
            // choices like `sel ? .blue : .red` capture `.blue`/`.red`.
            let expr = resolveTernaryBranch(arg.expression, env)
            let value = exprString(expr, env) ?? expr.trimmedDescription
            return ModifierArg(label: arg.label?.text, value: value)
        }
    }

    /// If `expr` is a ternary, evaluates the condition and returns the taken
    /// branch (recursively); otherwise returns `expr` unchanged.
    private func resolveTernaryBranch(_ expr: ExprSyntax, _ env: EvalEnvironment) -> ExprSyntax {
        guard let ternary = expr.as(TernaryExprSyntax.self) else { return expr }
        let taken = expressions.eval(ternary.condition, env)?.isTruthy ?? false
        return resolveTernaryBranch(taken ? ternary.thenExpression : ternary.elseExpression, env)
    }
}

/// One-shot result holder for ``SwiftViewInterpreter``'s large-stack worker:
/// written once on the worker thread, read on the caller only after the join
/// signal. Safe to mark `@unchecked Sendable` because access is serialized by
/// the join, not by concurrent sharing.
private final class LargeStackResultBox<T>: @unchecked Sendable {
    var value: T?
}
