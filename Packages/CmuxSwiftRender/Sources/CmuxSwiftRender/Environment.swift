import Foundation

/// A lexical scope mapping identifiers to ``SwiftValue``s, chained to a
/// parent for nested closures, loop bodies, and `if` branches.
///
/// The root environment holds `@State`-style values (the state bag); child
/// scopes hold `let` bindings and loop variables and shadow the parent.
final class Environment {
    private var values: [String: SwiftValue]
    private let parent: Environment?

    init(values: [String: SwiftValue] = [:], parent: Environment? = nil) {
        self.values = values
        self.parent = parent
    }

    /// Looks up `name`, walking up the scope chain.
    func lookup(_ name: String) -> SwiftValue? {
        values[name] ?? parent?.lookup(name)
    }

    /// Defines or overwrites `name` in this scope.
    func define(_ name: String, _ value: SwiftValue) {
        values[name] = value
    }

    /// A fresh child scope for a loop body, `if` branch, or closure.
    func makeChild() -> Environment {
        Environment(parent: self)
    }
}
