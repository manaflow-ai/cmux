public import Foundation

/// The tab a sign-in opened for its provider's page (the app's `LinkOpener.openSignInPage`: Settings >
/// Accounts, onboarding), by its `Surface`. Once that sign-in is cancelled, finishes or its code expires the
/// tab closes, and only that tab: never one the person opened. It closes only while it still shows a page on
/// one of `hosts`, the sign-in's own hosts as acpmux names them (the start's `pageHosts`,
/// `agent_login::parse::page_hosts`); a tab the person took anywhere else is theirs and stays. A sign-in
/// that ends before its tab is listed closes the tab as it arrives (it shows the page it was opened on).
@MainActor
public final class SignInPageTab<Surface> {
    private let hosts: [String]
    private let shown: @MainActor (Surface) -> URL?
    private let close: @MainActor (Surface) -> Void
    private var surface: Surface?
    private var ended = false

    nonisolated deinit {}

    /// `shown`: the page the tab on a surface shows now, nil while the tab is not listed yet (it still loads
    /// the page it was opened on). `close`: closes that tab, now or as it arrives.
    public init(hosts: [String], shown: @escaping @MainActor (Surface) -> URL?, close: @escaping @MainActor (Surface) -> Void) {
        self.hosts = hosts.map { $0.lowercased() }
        self.shown = shown
        self.close = close
    }

    /// The open reported the tab's surface.
    public func made(_ surface: Surface) {
        self.surface = surface
        if ended { closeIfStill() }
    }

    /// The sign-in ended: its tab closes now, or as its open reports it.
    public func end() {
        ended = true
        closeIfStill()
    }

    private func closeIfStill() {
        guard let surface, !hosts.isEmpty else { return }
        self.surface = nil
        if let page = shown(surface), !SignInPageHosts.still(page, on: hosts) { return }
        close(surface)
    }
}

/// The rule for a sign-in's page, apart from any tab.
public struct SignInPageHosts {
    public init() {}
    /// Whether a tab showing `shown` is still on the sign-in's page: an https page, no user or port, on one of `hosts`.
    public static func still(_ shown: URL, on hosts: [String]) -> Bool {
        guard shown.scheme?.lowercased() == "https", shown.user == nil, shown.password == nil, shown.port == nil,
              let host = shown.host?.lowercased() else { return false }
        return hosts.contains(host)
    }
}
