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
///
/// A root scope can carry an external `resolver` consulted only when a name
/// misses the whole chain. Live-evaluation engines use this so reads of
/// `@State`-backed values stay lazy: the resolver touches observable storage
/// at lookup time, which is what registers Observation dependencies.
public final class EvalEnvironment {
    private var values: [String: SwiftValue]
    private var functions: [String: FunctionDeclSyntax]
    private let parent: EvalEnvironment?
    private let externalResolver: ((String) -> SwiftValue?)?
    /// Shared across the whole scope chain; bounds interpreter recursion so
    /// pathological authored source can't overflow the stack.
    let budget: RecursionBudget

    init(values: [String: SwiftValue] = [:], parent: EvalEnvironment? = nil) {
        self.values = values
        self.functions = [:]
        self.parent = parent
        self.externalResolver = nil
        self.budget = parent?.budget ?? RecursionBudget()
    }

    /// A root scope whose lookup misses fall through to `resolver`.
    ///
    /// The resolver runs on every miss (results are not cached here), so an
    /// engine backing names with observable boxes registers a dependency
    /// exactly when, and only when, the name is actually read.
    public init(values: [String: SwiftValue] = [:], resolver: @escaping (String) -> SwiftValue?) {
        self.values = values
        self.functions = [:]
        self.parent = nil
        self.externalResolver = resolver
        self.budget = RecursionBudget()
    }

    /// Looks up `name`, walking up the scope chain, then asking the root's
    /// external resolver.
    public func lookup(_ name: String) -> SwiftValue? {
        values[name] ?? (parent?.lookup(name) ?? externalResolver?(name))
    }

    /// Defines or overwrites `name` in this scope.
    public func define(_ name: String, _ value: SwiftValue) {
        values[name] = value
    }

    /// Registers a user-defined function in this scope.
    public func defineFunction(_ name: String, _ decl: FunctionDeclSyntax) {
        functions[name] = decl
    }

    /// Looks up a user-defined function by name, walking up the scope chain.
    public func lookupFunction(_ name: String) -> FunctionDeclSyntax? {
        functions[name] ?? parent?.lookupFunction(name)
    }

    /// A fresh child scope for a loop body, `if` branch, or closure.
    public func makeChild() -> EvalEnvironment {
        EvalEnvironment(parent: self)
    }

    /// Copies the visible values and functions into a fresh root scope for a
    /// deferred view-builder body. The fresh budget is important: evaluating a
    /// menu later must not consume the row tree's node budget, and a menu that
    /// is opened after the row render must still have a full bounded budget.
    func snapshotForDeferredContent() -> EvalEnvironment {
        let snapshot: EvalEnvironment
        if let resolver = rootResolver() {
            snapshot = EvalEnvironment(values: flattenedValues(), resolver: resolver)
        } else {
            snapshot = EvalEnvironment(values: flattenedValues())
        }
        for (name, function) in flattenedFunctions() {
            snapshot.defineFunction(name, function)
        }
        return snapshot
    }

    private func flattenedValues() -> [String: SwiftValue] {
        var result = parent?.flattenedValues() ?? [:]
        for (name, value) in values {
            result[name] = value
        }
        return result
    }

    private func flattenedFunctions() -> [String: FunctionDeclSyntax] {
        var result = parent?.flattenedFunctions() ?? [:]
        for (name, function) in functions {
            result[name] = function
        }
        return result
    }

    private func rootResolver() -> ((String) -> SwiftValue?)? {
        parent?.rootResolver() ?? externalResolver
    }
}
