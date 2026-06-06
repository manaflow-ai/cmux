import Foundation
import SwiftSyntax

/// A lexical scope mapping identifiers to ``SwiftValue``s (and user-defined
/// functions), chained to a parent for nested closures, loop bodies, and
/// `if` branches.
///
/// The root environment holds `@State`-style values (the state bag); child
/// scopes hold `let` bindings and loop variables and shadow the parent.
/// User `func` declarations are registered so value and view helpers can be
/// called from anywhere in the same or a nested scope.
final class Environment {
    private var values: [String: SwiftValue]
    private var functions: [String: FunctionDeclSyntax]
    private let parent: Environment?
    /// Shared across the whole scope chain; bounds interpreter recursion so
    /// pathological authored source can't overflow the stack.
    let budget: RecursionBudget

    init(values: [String: SwiftValue] = [:], parent: Environment? = nil) {
        self.values = values
        self.functions = [:]
        self.parent = parent
        self.budget = parent?.budget ?? RecursionBudget()
    }

    /// Looks up `name`, walking up the scope chain.
    func lookup(_ name: String) -> SwiftValue? {
        values[name] ?? parent?.lookup(name)
    }

    /// Defines or overwrites `name` in this scope.
    func define(_ name: String, _ value: SwiftValue) {
        values[name] = value
    }

    /// Registers a user-defined function in this scope.
    func defineFunction(_ name: String, _ decl: FunctionDeclSyntax) {
        functions[name] = decl
    }

    /// Looks up a user-defined function by name, walking up the scope chain.
    func lookupFunction(_ name: String) -> FunctionDeclSyntax? {
        functions[name] ?? parent?.lookupFunction(name)
    }

    /// A fresh child scope for a loop body, `if` branch, or closure.
    func makeChild() -> Environment {
        Environment(parent: self)
    }
}
