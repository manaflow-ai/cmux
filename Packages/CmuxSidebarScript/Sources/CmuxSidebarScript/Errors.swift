import Foundation

/// An error raised while reading or evaluating a sidebar script.
///
/// `message` is a localized, user-facing sentence: these errors are surfaced in
/// the UI when a user's `sidebar.lisp` is malformed, so they must read well.
public struct LispError: Error, CustomStringConvertible {
    public enum Stage: String {
        case read
        case eval
    }

    public let stage: Stage
    public let message: String
    /// 1-based source line, when known.
    public let line: Int?

    public init(stage: Stage, message: String, line: Int? = nil) {
        self.stage = stage
        self.message = message
        self.line = line
    }

    public var description: String {
        if let line {
            let prefix = String(
                localized: "sidebarScript.error.linePrefix",
                defaultValue: "Line \(line): ",
                bundle: .module
            )
            return prefix + message
        }
        return message
    }

    // MARK: Factories

    static func read(_ message: String, line: Int? = nil) -> LispError {
        LispError(stage: .read, message: message, line: line)
    }

    static func eval(_ message: String) -> LispError {
        LispError(stage: .eval, message: message)
    }

    static func unbound(_ name: String) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.unbound",
            defaultValue: "Unknown name '\(name)'.",
            bundle: .module
        ))
    }

    static func notCallable(_ value: LispValue) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.notCallable",
            defaultValue: "Tried to call a \(value.typeName), which is not a function.",
            bundle: .module
        ))
    }

    static func arity(_ fn: String, expected: String, got: Int) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.arity",
            defaultValue: "'\(fn)' expects \(expected) but got \(got).",
            bundle: .module
        ))
    }

    static func type(_ fn: String, expected: String, got: LispValue) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.type",
            defaultValue: "'\(fn)' expects \(expected) but got a \(got.typeName).",
            bundle: .module
        ))
    }

    static func unknownModifier(_ name: String, on view: String) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.unknownModifier",
            defaultValue: "'\(view)' has no ':\(name)' option.",
            bundle: .module
        ))
    }

    static func unknownView(_ name: String) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.unknownView",
            defaultValue: "Unknown view '\(name)'.",
            bundle: .module
        ))
    }

    static func immutableBinding(_ name: String) -> LispError {
        .eval(String(
            localized: "sidebarScript.error.immutableBinding",
            defaultValue: "Cannot change top-level binding '\(name)' while rendering.",
            bundle: .module
        ))
    }

    static var stepLimit: LispError {
        .eval(String(
            localized: "sidebarScript.error.stepLimit",
            defaultValue: "Script did too much work (possible infinite loop).",
            bundle: .module
        ))
    }

    static var collectionLimit: LispError {
        .eval(String(
            localized: "sidebarScript.error.collectionLimit",
            defaultValue: "Script tried to create too many values at once.",
            bundle: .module
        ))
    }

    static var depthLimit: LispError {
        .eval(String(
            localized: "sidebarScript.error.depthLimit",
            defaultValue: "Script recursed too deeply.",
            bundle: .module
        ))
    }
}
