import Foundation

/// A lexical scope. `define` writes into the current scope; lookup and `set!`
/// walk up the parent chain.
public final class LispEnvironment {
    private var vars: [String: LispValue]
    public let parent: LispEnvironment?

    public init(parent: LispEnvironment? = nil) {
        self.vars = [:]
        self.parent = parent
    }

    public func define(_ name: String, _ value: LispValue) {
        vars[name] = value
    }

    public func lookup(_ name: String) -> LispValue? {
        var scope: LispEnvironment? = self
        while let s = scope {
            if let v = s.vars[name] { return v }
            scope = s.parent
        }
        return nil
    }

    @discardableResult
    public func set(_ name: String, _ value: LispValue) -> Bool {
        var scope: LispEnvironment? = self
        while let s = scope {
            if s.vars[name] != nil {
                s.vars[name] = value
                return true
            }
            scope = s.parent
        }
        return false
    }

    /// A child scope. Used for function calls and `let`.
    public func child() -> LispEnvironment {
        LispEnvironment(parent: self)
    }
}
