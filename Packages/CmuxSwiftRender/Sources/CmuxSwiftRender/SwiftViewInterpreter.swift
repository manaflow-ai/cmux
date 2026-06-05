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
/// evaluated against an ``Environment`` seeded with `@State`-style values.
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
    public func parse(_ source: String) -> ParsedProgram {
        let parsed = Parser.parse(source: source)
        let file = (try? OperatorTable.standardOperators.foldAll(parsed))?
            .as(SourceFileSyntax.self) ?? parsed
        return ParsedProgram(file: file)
    }

    /// Interprets an already-parsed ``ParsedProgram``'s first top-level
    /// expression against an environment seeded with `state`. Returns `nil`
    /// when nothing supported is found.
    public func evaluate(_ program: ParsedProgram, state: [String: SwiftValue] = [:]) -> RenderNode? {
        let env = Environment(values: state)
        registerFunctions(program.file.statements, env)
        for item in program.file.statements {
            if let expr = item.item.as(ExprSyntax.self), let node = evalView(expr, env) {
                return node
            }
        }
        return nil
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

    /// Registers any `func` declarations in `items` into `env` so value and
    /// view helpers can be called (including before their declaration).
    private func registerFunctions(_ items: CodeBlockItemListSyntax, _ env: Environment) {
        for item in items {
            if let fn = item.item.as(FunctionDeclSyntax.self) {
                env.defineFunction(fn.name.text, fn)
            }
        }
    }

    private func bindParameters(_ decl: FunctionDeclSyntax, _ call: FunctionCallExprSyntax, _ env: Environment) -> Environment {
        expressions.bindParameters(decl, call, env)
    }

    // MARK: - View expressions

    private func evalView(_ expr: ExprSyntax, _ env: Environment) -> RenderNode? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        return evalCall(call, env)
    }

    private func evalCall(_ call: FunctionCallExprSyntax, _ env: Environment) -> RenderNode? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base, var node = evalView(base, env) else { return nil }
            let name = member.declName.baseName.text
            // `.onTapGesture { … }` makes any view tappable; capture its
            // closure as the node's action so rich rows can run commands.
            if name == "onTapGesture", let closure = call.trailingClosure {
                node.action = parseAction(closure, env)
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
        case "RoundedRectangle":
            return RenderNode(kind: .roundedRectangle, cornerRadius: doubleArgument(named: "cornerRadius", call.arguments, env))
        case "VStack", "HStack", "ZStack":
            let kind: RenderNode.Kind = ref.baseName.text == "VStack" ? .vstack
                : ref.baseName.text == "HStack" ? .hstack : .zstack
            let children = call.trailingClosure.map { evalItems($0.statements, env) } ?? []
            return RenderNode(kind: kind, spacing: doubleArgument(named: "spacing", call.arguments, env), children: children)
        case "HSplitView":
            return RenderNode(kind: .hsplit, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
        case "ScrollView":
            // The sidebar already scrolls; treat ScrollView as a passthrough
            // vertical container so authored ScrollViews render correctly.
            return RenderNode(kind: .vstack, children: call.trailingClosure.map { evalItems($0.statements, env) } ?? [])
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

    private func evalItems(_ items: CodeBlockItemListSyntax, _ env: Environment) -> [RenderNode] {
        registerFunctions(items, env)
        var out: [RenderNode] = []
        for item in items {
            let node = item.item
            if let decl = node.as(VariableDeclSyntax.self) {
                applyBinding(decl, env)
            } else if let loop = node.as(ForStmtSyntax.self) {
                out += evalFor(loop, env)
            } else if let ifExpr = ifExpression(node) {
                out += evalIf(ifExpr, env)
            } else if let ret = node.as(ReturnStmtSyntax.self), let expr = ret.expression {
                // A view helper with an explicit `return SomeView` (or
                // `return ForEach(...) { }`) renders its returned expression,
                // not nothing.
                if let call = expr.as(FunctionCallExprSyntax.self), isForEach(call) {
                    out += evalForEach(call, env)
                } else if let child = evalView(expr, env) {
                    out.append(child)
                }
            } else if let expr = node.as(ExprSyntax.self) {
                if let call = expr.as(FunctionCallExprSyntax.self), isForEach(call) {
                    out += evalForEach(call, env)
                } else if let child = evalView(expr, env) {
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

    /// Evaluates `Reorderable(data, move: "method", id: "field") { item in row }`
    /// into a `.reorderable` node: one rendered row per item plus a
    /// ``ReorderSpec`` carrying the item ids and the drop command.
    private func evalReorderable(_ call: FunctionCallExprSyntax, _ env: Environment) -> RenderNode? {
        guard let dataExpr = call.arguments.first(where: { $0.label == nil })?.expression,
              case let .array(items)? = expressions.eval(dataExpr, env),
              let closure = call.trailingClosure else { return nil }
        let method = labeledStringArgument("move", call.arguments, env) ?? "workspace.reorder"
        let idField = labeledStringArgument("id", call.arguments, env) ?? "id"
        let idParam = labeledStringArgument("idParam", call.arguments, env) ?? "workspace_id"
        let indexParam = labeledStringArgument("indexParam", call.arguments, env) ?? "index"
        let paramName = closureParameterName(closure)

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

    private func labeledStringArgument(_ label: String, _ args: LabeledExprListSyntax, _ env: Environment) -> String? {
        guard let expr = args.first(where: { $0.label?.text == label })?.expression else { return nil }
        return exprString(expr, env)
    }

    private func isForEach(_ call: FunctionCallExprSyntax) -> Bool {
        call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "ForEach"
    }

    /// Expands `ForEach(<sequence>) { item in … }` into a flat list of nodes,
    /// binding the closure parameter (or `$0`) to each element.
    private func evalForEach(_ call: FunctionCallExprSyntax, _ env: Environment) -> [RenderNode] {
        guard let sequenceExpr = call.arguments.first?.expression,
              let sequence = expressions.eval(sequenceExpr, env),
              let values = sequence.iterationValues,
              let closure = call.trailingClosure else { return [] }
        let name = closureParameterName(closure)
        var out: [RenderNode] = []
        for value in values {
            let scope = env.makeChild()
            if let name { scope.define(name, value) }
            scope.define("$0", value)
            out += evalItems(closure.statements, scope)
        }
        return out
    }

    private func closureParameterName(_ closure: ClosureExprSyntax) -> String? {
        guard let parameterClause = closure.signature?.parameterClause else { return nil }
        if case let .simpleInput(list) = parameterClause {
            return list.first?.name.text
        }
        if case let .parameterClause(clause) = parameterClause {
            return clause.parameters.first?.firstName.text
        }
        return nil
    }

    /// Captures the commands in a `Button` action closure (currently
    /// `cmux("method", args…)` calls), evaluating argument expressions
    /// against `env` so loop-captured values are baked in.
    private func parseAction(_ closure: ClosureExprSyntax, _ env: Environment) -> ButtonAction {
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

    private func evalFor(_ loop: ForStmtSyntax, _ env: Environment) -> [RenderNode] {
        guard let name = loop.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
              let sequence = expressions.eval(loop.sequence, env),
              let values = sequence.iterationValues else { return [] }
        var out: [RenderNode] = []
        for value in values {
            let scope = env.makeChild()
            scope.define(name, value)
            out += evalItems(loop.body.statements, scope)
        }
        return out
    }

    private func evalIf(_ ifExpr: IfExprSyntax, _ env: Environment) -> [RenderNode] {
        let taken = ifExpr.conditions.allSatisfy { element in
            guard let expr = element.condition.as(ExprSyntax.self) else { return false }
            return expressions.eval(expr, env)?.isTruthy ?? false
        }
        if taken {
            return evalItems(ifExpr.body.statements, env.makeChild())
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

    private func applyBinding(_ decl: VariableDeclSyntax, _ env: Environment) {
        for binding in decl.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let value = binding.initializer.map({ expressions.eval($0.value, env) }) ?? nil else { continue }
            env.define(name, value)
        }
    }

    // MARK: - Argument helpers

    private func stringArgument(_ args: LabeledExprListSyntax, _ env: Environment) -> String? {
        guard let first = args.first?.expression else { return nil }
        return exprString(first, env)
    }

    /// Resolves an expression to a string: literal segments (with
    /// interpolation) or any value's display form.
    private func exprString(_ expr: ExprSyntax, _ env: Environment) -> String? {
        if let literal = expr.as(StringLiteralExprSyntax.self) {
            return expressions.evalString(literal, env)
        }
        return expressions.eval(expr, env)?.displayString
    }

    private func doubleArgument(named label: String, _ args: LabeledExprListSyntax, _ env: Environment) -> Double? {
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
    private func modifierArgs(_ args: LabeledExprListSyntax, _ env: Environment) -> [ModifierArg] {
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
    private func resolveTernaryBranch(_ expr: ExprSyntax, _ env: Environment) -> ExprSyntax {
        guard let ternary = expr.as(TernaryExprSyntax.self) else { return expr }
        let taken = expressions.eval(ternary.condition, env)?.isTruthy ?? false
        return resolveTernaryBranch(taken ? ternary.thenExpression : ternary.elseExpression, env)
    }
}
