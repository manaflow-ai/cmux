import Foundation

/// A ``ProviderScriptGate`` from a tab lookup and the guard's four answers, so the app passes its
/// one login guard in without an adapter type of its own.
@MainActor
public final class PageScriptGate: ProviderScriptGate {
    /// A tab's current URL and browser profile id, as the control socket's topology names them.
    public typealias Page = (url: String?, profile: String?)

    private let page: @MainActor (String) -> Page
    private let admit: @MainActor (String, Page) async -> String?
    private let ran: @MainActor (String, Page) async -> Void
    private let capture: @MainActor (String, Page) async -> String?
    private let admitRaw: @MainActor (String, Page) async -> String?
    private let raw: @MainActor (Page) -> String?
    private let rawEnded: @MainActor (String) -> Void

    public init(page: @escaping @MainActor (String) -> Page,
                admit: @escaping @MainActor (String, Page) async -> String?,
                ran: @escaping @MainActor (String, Page) async -> Void,
                capture: @escaping @MainActor (String, Page) async -> String?,
                admitRaw: @escaping @MainActor (String, Page) async -> String?,
                raw: @escaping @MainActor (Page) -> String?,
                rawEnded: @escaping @MainActor (String) -> Void) {
        self.page = page
        self.admit = admit
        self.ran = ran
        self.capture = capture
        self.admitRaw = admitRaw
        self.raw = raw
        self.rawEnded = rawEnded
    }

    public func admitAgentCode(targetID: String) async -> String? { await admit(targetID, page(targetID)) }

    public func agentCodeRan(targetID: String) async { await ran(targetID, page(targetID)) }

    public func admitCapture(targetID: String) async -> String? { await capture(targetID, page(targetID)) }

    public func admitRawDevTools(targetID: String) async -> String? { await admitRaw(targetID, page(targetID)) }

    public func rawDevToolsMessage(targetID: String) -> String? { raw(page(targetID)) }

    public func rawDevToolsEnded(targetID: String) { rawEnded(targetID) }
}
