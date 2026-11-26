import CmuxSwiftRender
import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax

/// A parsed live-eval program: `@State` declarations, user `func` helpers,
/// and the top-level view expression.
///
/// Parsing happens once per source edit; every body re-evaluation walks the
/// cached syntax tree against live observable state.
public struct LiveProgram: Sendable {
    /// `@State var name = initial` declarations, in source order.
    public let stateDeclarations: [LiveStateDeclaration]
    /// Top-level `func` helpers, registered into every evaluation scope.
    public let functions: [FunctionDeclSyntax]
    /// The first top-level expression: the view body to re-evaluate.
    public let body: ExprSyntax?

    /// Parses `source` (operator-folded) and extracts state declarations,
    /// functions, and the view body expression.
    public static func parse(_ source: String) -> LiveProgram {
        let parsed = Parser.parse(source: source)
        let file = (try? OperatorTable.standardOperators.foldAll(parsed))?
            .as(SourceFileSyntax.self) ?? parsed

        var stateDeclarations: [LiveStateDeclaration] = []
        var functions: [FunctionDeclSyntax] = []
        var body: ExprSyntax?
        let expressions = ExpressionEvaluator()
        let environment = EvalEnvironment(resolver: { _ in nil })

        for item in file.statements {
            if let variable = item.item.as(VariableDeclSyntax.self) {
                stateDeclarations += Self.stateDeclarations(in: variable, expressions, environment)
            } else if let function = item.item.as(FunctionDeclSyntax.self) {
                functions.append(function)
            } else if body == nil, let expression = item.item.as(ExprSyntax.self) {
                body = expression
            }
        }
        return LiveProgram(stateDeclarations: stateDeclarations, functions: functions, body: body)
    }

    /// Extracts `@State`-attributed bindings from one variable declaration,
    /// evaluating initializers in a pure (state-free) environment.
    private static func stateDeclarations(
        in variable: VariableDeclSyntax,
        _ expressions: ExpressionEvaluator,
        _ environment: EvalEnvironment
    ) -> [LiveStateDeclaration] {
        let isState = variable.attributes.contains { attribute in
            attribute.as(AttributeSyntax.self)?
                .attributeName.as(IdentifierTypeSyntax.self)?.name.text == "State"
        }
        guard isState else { return [] }
        var declarations: [LiveStateDeclaration] = []
        for binding in variable.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  let initializer = binding.initializer?.value,
                  let value = expressions.eval(initializer, environment)
            else { continue }
            declarations.append(LiveStateDeclaration(name: name, initialValue: value))
        }
        return declarations
    }
}
