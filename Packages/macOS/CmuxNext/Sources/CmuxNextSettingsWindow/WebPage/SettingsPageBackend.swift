public import CmuxNextSettings
import Foundation

/// Where the web Settings page's `settings.*` operations go. The owner is
/// the daemon's config actor (plans/cmux-next/settings-react.md section 1);
/// the bridge forwards each operation unchanged and never interprets it.
@MainActor
public protocol SettingsPageBackend: AnyObject {
    /// Runs `operation` (`settings.list`, `settings.snapshot`, `settings.set`,
    /// `settings.reset`, `settings.reset_all`) and returns its result, or
    /// throws `SettingsPageError` with the owner's refusal code.
    func request(_ operation: String, params: JSONValue) async throws -> JSONValue
    /// Called with every committed change (revision and changed keys).
    var onChange: ((_ revision: Int, _ keys: [String]) -> Void)? { get set }
}

/// A refusal in the wire shape the page reads (`{error: {code, message, details}}`).
public struct SettingsPageError: Error, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue?

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    var reply: JSONValue {
        var error: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let details { error["details"] = details }
        return ["error": .object(error)]
    }
}
