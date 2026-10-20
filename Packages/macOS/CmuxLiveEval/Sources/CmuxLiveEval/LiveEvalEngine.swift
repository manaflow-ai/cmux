import CmuxSwiftRender
import SwiftSyntax
import SwiftUI

/// Live-evaluation engine: walks an interpreted ViewBuilder AST one nesting
/// level at a time, producing shallow ``LiveNode``s whose children stay
/// unevaluated until a nested compiled stub view's body asks for them.
///
/// All state reads go through ``LiveScope/resolve(_:)`` into `@Observable`
/// ``StateBox``es, so whatever SwiftUI body (or `withObservationTracking`
/// scope) triggered the evaluation registers dependencies on exactly the
/// boxes the evaluated subtree read.
///
/// Main-thread only, like the SwiftUI views that drive it.
@MainActor
public final class LiveEvalEngine {
    let expressions = ExpressionEvaluator()
    /// Instrumentation hook: called with a short label each time a block is
    /// expanded or a statement subtree is evaluated. Tests and benchmarks
    /// use it to count per-subtree re-evaluations.
    public var onEvaluate: ((String) -> Void)?
    /// RNG behind interpreted `.shuffle()`, injectable so tests are
    /// deterministic.
    public var random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    /// When set, stub views call `Self._printChanges()` in their bodies.
    public var tracesBodyChanges = false
    public let program: LiveProgram

    public init(program: LiveProgram) {
        self.program = program
    }

    /// Fresh observable state storage seeded from the program's `@State`
    /// declarations.
    public func makeStore() -> LiveStateStore {
        LiveStateStore(declarations: program.stateDeclarations)
    }

    /// Evaluates the program's top-level view expression one level deep.
    public func evaluateRoot(_ scope: LiveScope) -> LiveNode {
        note("root")
        guard let body = program.body else { return .empty }
        return evaluateViewExpression(body, scope) ?? .empty
    }

    /// Expands a block into renderable statement entries, evaluating `let`
    /// bindings (in order) into a child scope shared by later statements.
    ///
    /// Blocks without `let`s keep the block's own scope reference, so the
    /// produced entries are stable across expansions and nested stub views
    /// see unchanged inputs.
    public func expandBlock(_ block: LiveBlock) -> [LiveBlockEntry] {
        note("block")
        var scope = block.scope
        var entries: [LiveBlockEntry] = []
        for (index, item) in block.statements.enumerated() {
            if let variable = item.item.as(VariableDeclSyntax.self) {
                if scope === block.scope { scope = block.scope.child() }
                defineBindings(variable, scope)
            } else if item.item.is(FunctionDeclSyntax.self) {
                continue // Top-level funcs are registered per-evaluation; nested funcs are out of spike scope.
            } else {
                entries.append(LiveBlockEntry(id: index, statement: item, scope: scope))
            }
        }
        return entries
    }

    /// Evaluates one ViewBuilder statement into zero or more shallow nodes.
    public func evaluateStatement(_ item: CodeBlockItemSyntax, _ scope: LiveScope) -> [LiveNode] {
        if let onEvaluate {
            onEvaluate(Self.label(for: item))
        }
        if let ifExpression = Self.ifExpression(item.item) {
            return evaluateIf(ifExpression, scope)
        }
        guard let expression = item.item.as(ExprSyntax.self) else { return [] }
        if let call = expression.as(FunctionCallExprSyntax.self), Self.isForEach(call) {
            return [evaluateForEach(call, scope)]
        }
        guard let node = evaluateViewExpression(expression, scope) else { return [] }
        return [node]
    }

    // MARK: - View expressions

    /// Evaluates a view-position expression one level deep. Modifier chains
    /// are unwrapped to their base view; the modifiers themselves are not
    /// applied (leaf fidelity is out of spike scope; ``RenderNode`` already
    /// proves the modifier-table approach).
    func evaluateViewExpression(_ expression: ExprSyntax, _ scope: LiveScope) -> LiveNode? {
        guard let call = expression.as(FunctionCallExprSyntax.self) else { return nil }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return nil }
            return evaluateViewExpression(base, scope)
        }
        guard let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return nil }
        let environment = makeEnvironment(scope)
        switch reference.baseName.text {
        case "Text":
            return .text(stringArgument(call.arguments.first?.expression, environment) ?? "")
        case "Button":
            let title = stringArgument(call.arguments.first?.expression, environment) ?? ""
            guard let closure = call.trailingClosure else { return .button(title: title, action: {}) }
            return .button(title: title, action: { [weak self] in
                self?.executeAction(closure, scope)
            })
        case "TextField":
            let placeholder = stringArgument(call.arguments.first(where: { $0.label == nil })?.expression, environment) ?? ""
            guard let bindingExpression = call.arguments.first(where: { $0.label?.text == "text" })?.expression,
                  let accessor = LiveStateAccessor.resolve(bindingExpression, scope)
            else { return .empty }
            return .textField(placeholder: placeholder, text: accessor.stringBinding())
        case "Toggle":
            let title = stringArgument(call.arguments.first(where: { $0.label == nil })?.expression, environment) ?? ""
            guard let bindingExpression = call.arguments.first(where: { $0.label?.text == "isOn" })?.expression,
                  let accessor = LiveStateAccessor.resolve(bindingExpression, scope)
            else { return .empty }
            return .toggle(title: title, isOn: accessor.boolBinding())
        case "VStack", "HStack", "ZStack":
            let axis: LiveStackAxis = reference.baseName.text == "VStack"
                ? .vertical
                : (reference.baseName.text == "HStack" ? .horizontal : .depth)
            let spacing = doubleArgument(named: "spacing", call.arguments, environment)
            let statements = call.trailingClosure.map { Array($0.statements) } ?? []
            return .stack(axis: axis, spacing: spacing, content: LiveBlock(statements: statements, scope: scope))
        case "ForEach":
            return evaluateForEach(call, scope)
        case "Spacer":
            return .spacer
        case "Divider":
            return .divider
        default:
            return nil
        }
    }

    /// Expands `ForEach(sequence, id: \.field) { element in … }` into
    /// identified rows whose blocks stay unevaluated. Reading the sequence
    /// registers the dependency on the collection's box; row contents
    /// register only inside each row's own stub body.
    ///
    /// A projected form `ForEach($rows, id: \.id) { $row in … }` additionally
    /// records binding provenance (box + row identity) for the loop variable,
    /// so `$row.isOn` resolves to a Binding that follows the row by identity
    /// across reorders.
    private func evaluateForEach(_ call: FunctionCallExprSyntax, _ scope: LiveScope) -> LiveNode {
        guard let sequenceExpression = call.arguments.first?.expression,
              let closure = call.trailingClosure
        else { return .empty }
        var bindingBox: StateBox?
        let sequence: SwiftValue?
        if let reference = sequenceExpression.as(DeclReferenceExprSyntax.self),
           reference.baseName.text.hasPrefix("$"),
           let box = scope.stateBox(String(reference.baseName.text.dropFirst())) {
            bindingBox = box
            sequence = box.value // Tracked read: registers the collection dependency.
        } else {
            sequence = expressions.eval(sequenceExpression, makeEnvironment(scope))
        }
        guard let values = sequence?.iterationValues else { return .empty }
        let idField = Self.keyPathField(call.arguments.first(where: { $0.label?.text == "id" })?.expression)
        var parameter = Self.closureParameterNames(closure).first
        let isProjected = parameter?.hasPrefix("$") ?? false
        if isProjected { parameter = parameter.map { String($0.dropFirst()) } }
        let identityField = (idField == "self") ? nil : idField
        let statements = Array(closure.statements)
        var rows: [LiveForEachRow] = []
        for value in values {
            var locals: [String: SwiftValue] = ["$0": value]
            if let parameter { locals[parameter] = value }
            let rowScope = scope.child(locals: locals)
            let idValue = identityField.flatMap { value.member($0) } ?? value
            if isProjected, let bindingBox, let parameter {
                rowScope.defineProvenance(
                    parameter,
                    LiveBindingProvenance(box: bindingBox, idField: identityField, idValue: idValue)
                )
            }
            rows.append(LiveForEachRow(id: idValue.displayString, content: LiveBlock(statements: statements, scope: rowScope)))
        }
        return .forEach(rows: rows)
    }

    /// Evaluates an `if`/`else`: the condition reads register to the caller
    /// (the statement's stub body); the taken branch renders as a nested
    /// group block so branch contents register to their own stubs.
    private func evaluateIf(_ ifExpression: IfExprSyntax, _ scope: LiveScope) -> [LiveNode] {
        let branchScope = scope.child()
        if conditionsPass(ifExpression.conditions, branchScope) {
            return [.stack(axis: .vertical, spacing: nil, content: LiveBlock(statements: Array(ifExpression.body.statements), scope: branchScope))]
        }
        guard let elseBody = ifExpression.elseBody else { return [] }
        if let block = elseBody.as(CodeBlockSyntax.self) {
            return [.stack(axis: .vertical, spacing: nil, content: LiveBlock(statements: Array(block.statements), scope: scope.child()))]
        }
        if let elseIf = elseBody.as(IfExprSyntax.self) {
            return evaluateIf(elseIf, scope)
        }
        return []
    }

    // MARK: - Helpers

    /// A fresh evaluation environment whose root lookups resolve through
    /// `scope` (lazily touching observable boxes) with the program's `func`
    /// helpers registered.
    func makeEnvironment(_ scope: LiveScope) -> EvalEnvironment {
        let environment = EvalEnvironment(resolver: { name in scope.resolve(name) })
        for function in program.functions {
            environment.defineFunction(function.name.text, function)
        }
        return environment
    }

    func executeAction(_ closure: ClosureExprSyntax, _ scope: LiveScope) {
        LiveActionExecutor(engine: self).execute(closure, scope)
    }

    /// Calls `_printChanges` for `type` when body tracing is on. Stub views
    /// call this first thing in `body` so invalidation causes are visible.
    public func traceBody<V: View>(_ type: V.Type) {
        guard tracesBodyChanges else { return }
        V._printChanges()
    }

    private func defineBindings(_ variable: VariableDeclSyntax, _ scope: LiveScope) {
        let environment = makeEnvironment(scope)
        for binding in variable.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let initializer = binding.initializer?.value,
                  let value = expressions.eval(initializer, environment)
            else { continue }
            scope.define(name, value)
        }
    }

    private func conditionsPass(_ conditions: ConditionElementListSyntax, _ scope: LiveScope) -> Bool {
        let environment = makeEnvironment(scope)
        for element in conditions {
            guard let expression = element.condition.as(ExprSyntax.self) else { return false }
            guard expressions.eval(expression, environment)?.isTruthy ?? false else { return false }
        }
        return true
    }

    private func stringArgument(_ expression: ExprSyntax?, _ environment: EvalEnvironment) -> String? {
        guard let expression else { return nil }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return expressions.evalString(literal, environment)
        }
        return expressions.eval(expression, environment)?.displayString
    }

    private func doubleArgument(named label: String, _ arguments: LabeledExprListSyntax, _ environment: EvalEnvironment) -> Double? {
        guard let expression = arguments.first(where: { $0.label?.text == label })?.expression else { return nil }
        switch expressions.eval(expression, environment) {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    private func note(_ label: String) {
        onEvaluate?(label)
    }

    private static func isForEach(_ call: FunctionCallExprSyntax) -> Bool {
        call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "ForEach"
    }

    private static func ifExpression(_ item: CodeBlockItemSyntax.Item) -> IfExprSyntax? {
        if let ifExpression = item.as(IfExprSyntax.self) { return ifExpression }
        if let statement = item.as(ExpressionStmtSyntax.self) { return statement.expression.as(IfExprSyntax.self) }
        if let expression = item.as(ExprSyntax.self) { return expression.as(IfExprSyntax.self) }
        return nil
    }

    /// `\.self` -> "self", `\.id` -> "id", else nil.
    private static func keyPathField(_ expression: ExprSyntax?) -> String? {
        guard let keyPath = expression?.as(KeyPathExprSyntax.self),
              let component = keyPath.components.last
        else { return nil }
        return component.component.trimmedDescription
    }

    private static func closureParameterNames(_ closure: ClosureExprSyntax) -> [String] {
        guard let parameterClause = closure.signature?.parameterClause else { return [] }
        if case let .simpleInput(list) = parameterClause {
            return list.map { $0.name.text }
        }
        if case let .parameterClause(clause) = parameterClause {
            return clause.parameters.map { $0.firstName.text }
        }
        return []
    }

    /// A short instrumentation label for a statement (first line, trimmed).
    static func label(for item: CodeBlockItemSyntax) -> String {
        let source = item.trimmedDescription
        let firstLine = source.prefix(while: { !$0.isNewline })
        return String(firstLine.prefix(48))
    }
}

/// One renderable statement of an expanded block, identified by its stable
/// index within the block.
public struct LiveBlockEntry: Identifiable {
    public let id: Int
    public let statement: CodeBlockItemSyntax
    public let scope: LiveScope

    public init(id: Int, statement: CodeBlockItemSyntax, scope: LiveScope) {
        self.id = id
        self.statement = statement
        self.scope = scope
    }
}
