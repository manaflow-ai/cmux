import Foundation

/// A lexical scope. `define` writes into the current scope; lookup and `set!`
/// walk up the parent chain.
public final class LispEnvironment {
    public enum SetResult {
        case assigned
        case missing
        case immutable
    }

    private var vars: [String: LispValue]
    private var isMutable: Bool
    public let parent: LispEnvironment?

    public init(parent: LispEnvironment? = nil, isMutable: Bool = true) {
        self.vars = [:]
        self.isMutable = isMutable
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

    public func freeze() {
        isMutable = false
    }

    @discardableResult
    public func set(_ name: String, _ value: LispValue) -> SetResult {
        var scope: LispEnvironment? = self
        while let s = scope {
            if s.vars[name] != nil {
                guard s.isMutable else { return .immutable }
                s.vars[name] = value
                return .assigned
            }
            scope = s.parent
        }
        return .missing
    }

    /// A child scope. Used for function calls and `let`.
    public func child() -> LispEnvironment {
        LispEnvironment(parent: self)
    }
}
