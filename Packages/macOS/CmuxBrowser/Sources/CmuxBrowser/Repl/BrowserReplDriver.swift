public import Foundation

/// A driver error with a protocol code (`not_found`, `stale`, `timeout`,
/// `unsupported`, `invalid`, `closed`).
public struct BrowserReplDriverError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    /// `Error.name` of a page exception (`TypeError`, ...), when there was one.
    public let errorName: String?

    public init(code: String, message: String, errorName: String? = nil) {
        self.code = code
        self.message = message
        self.errorName = errorName
    }

    /// The JSON object sent to the runtime: `{ code, message, errorName? }`.
    public var json: String {
        var object: [String: Any] = ["code": code, "message": message]
        if let errorName { object["errorName"] = errorName }
        return JSONSerialization.browserReplString(object) ?? #"{"code":"invalid","message":"error"}"#
    }
}

/// How a REPL session ended, which decides what becomes of the tabs it
/// opened (docs/browser-repl/README.md, Sessions and tabs).
public enum BrowserReplSessionEnd: Sendable, Equatable {
    /// Reset, closed by its client, or ended by itself.
    case closed
    /// Unused for the idle timeout (30 minutes).
    case idle

    /// Whether a tab the session opened (and did not `page.keep()`) closes
    /// with it. A session that idled out leaves a tab the user can see
    /// (shown in a visible window, the selected tab of its pane and
    /// workspace), which becomes the user's; a hidden one closes.
    public func closesOpenedTab(visibleToUser: Bool) -> Bool {
        true
    }
}

/// Receives driver events (`tab.created`, `dialog.opened`, ...).
public typealias BrowserReplDriverEventSink = @Sendable (_ name: String, _ payloadJSON: String) -> Void

/// An engine driver behind the REPL runtime. See
/// `docs/browser-repl/driver-protocol.md` for methods and events.
public protocol BrowserReplDriver: AnyObject, Sendable {
    /// Capability names beyond the core protocol (`cdp`, `route`, ...).
    var capabilities: [String] { get }

    /// Runs one protocol method.
    /// - Parameters:
    ///   - method: Protocol method name, for example `tab.navigate`.
    ///   - paramsJSON: JSON object with the method's params.
    /// - Returns: JSON result (`null` when the method has none).
    func call(method: String, paramsJSON: String) async -> Result<String, BrowserReplDriverError>

    /// Starts delivering events to `sink` until `detach()`.
    func attach(eventSink: @escaping BrowserReplDriverEventSink)

    /// Stops events and releases held dialogs, file choosers and input state.
    func detach()

    /// Like ``detach()``, for a session that ended `ending`: the tabs the
    /// session opened close, except those ``BrowserReplSessionEnd/closesOpenedTab(visibleToUser:)``
    /// keeps. A driver without tabs of its own ignores `ending`.
    func detach(ending: BrowserReplSessionEnd)

    /// The session's domain policy changed. The driver refuses navigations
    /// the policy blocks (redirects too), blocks subresources and frames with
    /// content rules built from it, and refuses reads and input on a tab
    /// whose page is blocked. The session calls this, never JavaScript.
    func setDomainPolicy(_ policy: BrowserReplDomainPolicy)

    /// The session's working and temporary directories changed (canonical
    /// paths): the only directories its tabs may show or load local files
    /// from. The session calls this, never JavaScript.
    func setFileRoots(_ roots: [String])

    /// The secrets other sessions typed into tabs (``BrowserReplTypedSecrets``),
    /// as a store that masks them, or `nil` when there are none. This
    /// session does not hold them, so its own store would not mask them: the
    /// session applies this store wherever it applies its own (fetch
    /// responses, files written and read back, output lines, errors,
    /// results and events). Called from any thread.
    func typedSecretRedaction() -> BrowserReplSecretStore?

    /// Gives the driver the session's check that a secret an
    /// `input.insertText` call carries (`secretName`, `secretRevision`) is
    /// still the one the session holds under that name: the session filled
    /// the value in when the call was made, and the agent may delete or
    /// replace the secret before the driver types it. The driver asks right
    /// before it commits the text and refuses a secret that fails. The
    /// session calls this, never JavaScript.
    func setSecretCheck(_ isCurrent: @escaping @Sendable (_ name: String, _ revision: Int) -> Bool)
}

extension BrowserReplDriver {
    public func detach(ending: BrowserReplSessionEnd) { detach() }

    public func setDomainPolicy(_ policy: BrowserReplDomainPolicy) {}

    public func setFileRoots(_ roots: [String]) {}

    public func typedSecretRedaction() -> BrowserReplSecretStore? { nil }

    public func setSecretCheck(_ isCurrent: @escaping @Sendable (_ name: String, _ revision: Int) -> Bool) {}
}

/// JSON helpers for values crossing the JavaScriptCore bridge.
extension JSONSerialization {
    /// Encodes a JSON-compatible value (fragments allowed).
    public static func browserReplString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes JSON text (fragments allowed). Returns `nil` for invalid JSON.
    public static func browserReplValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Decodes a JSON object, returning an empty dictionary for anything else.
    public static func browserReplObject(_ text: String) -> [String: Any] {
        browserReplValue(text) as? [String: Any] ?? [:]
    }
}
