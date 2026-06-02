import Foundation

/// A callable value.
///
/// Three kinds, distinguished by how arguments reach them:
/// - ``Kind/special``: receives **unevaluated** argument forms plus the call
///   environment, for control flow that can't eagerly evaluate its arguments.
/// - ``Kind/builtin``: receives already-evaluated arguments; the standard
///   library and SwiftUI bridge are builtins.
/// - ``Kind/closure``: a script-defined `fn`/`def` lambda, capturing its
///   defining environment.
public struct LispFunction {
    /// How a function is invoked.
    public enum Kind {
        /// A special form: arguments arrive unevaluated with the call environment.
        case special((_ args: [LispValue], _ env: LispEnvironment, _ ev: Evaluator) throws -> LispValue)
        /// A native builtin: arguments arrive evaluated.
        case builtin((_ args: [LispValue], _ ev: Evaluator) throws -> LispValue)
        /// A user closure with bound parameters, optional rest parameter, body
        /// forms, and the environment it captured at definition.
        case closure(params: [String], rest: String?, body: [LispValue], env: LispEnvironment)
    }

    /// The function's name, used in error messages and `display`.
    public let name: String
    /// How the function is invoked.
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}
