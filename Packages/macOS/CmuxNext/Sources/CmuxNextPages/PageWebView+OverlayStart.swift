import Foundation

/// Whether a document served from an overlay install started (Leo, 2026-11-14: "I want people to
/// not accidentally soft lock themselves and like have good recovery options or whatever"). From
/// commit until its page code first speaks to the host (any bridge message: every page boots through
/// the page client, which beats `cmux.page.heartbeat` at once while shown), a failed load, an ended
/// process, or silence for ``readyWithin`` while shown means the install did not start, and the app
/// falls back to the bundled pages (``WebDevOverride/overlayDidNotStart(_:page:why:)``).
public nonisolated struct OverlayStartCheck: Equatable, Sendable {
    /// How long a shown document from an overlay has to speak. Generous: a page that works speaks
    /// within a frame or two of its first paint.
    public static let readyWithin: Duration = .seconds(20)

    /// The install the current document came from, until it spoke; nil when it came from elsewhere.
    public private(set) var watching: WebDevOverride.OverlayInstall?

    public init() {}

    /// A new document committed, served from `install` (nil: not from an overlay).
    public mutating func committed(_ install: WebDevOverride.OverlayInstall?) { watching = install }

    /// Its page code spoke: it started. True when this ended a watch.
    public mutating func spoke() -> Bool {
        defer { watching = nil }
        return watching != nil
    }

    /// Its load failed or its process ended: the install it did not start from, nil for none.
    public mutating func failed() -> WebDevOverride.OverlayInstall? {
        defer { watching = nil }
        return watching
    }

    /// ``readyWithin`` passed without a word: the install, when the page is `shown`. A hidden page
    /// sends no beat and may make no call yet, so it is not judged by time; a failure still counts.
    public mutating func deadline(shown: Bool) -> WebDevOverride.OverlayInstall? {
        shown ? failed() : nil
    }
}

@MainActor
extension PageWebView {
    /// The install the document now loading comes from: the overlay serves this page's folder and
    /// no server (the launch variable's, web-dev.json's or a projection window's) wins over it.
    var overlayInstallServingDocument: WebDevOverride.OverlayInstall? {
        guard PageDevServer.current == nil else { return nil }
        let live = WebProjection.shared.override(for: webView)
        guard let install = live.servedInstall, let root = Self.servedRoot(for: descriptor),
              live.overlayRoot(for: descriptor, bundledRoot: root) != nil
        else { return nil }
        return install
    }

    /// A document committed: watch its start when an overlay served it.
    func watchOverlayStart() {
        overlayStartTimer.cancel()
        let install = overlayInstallServingDocument
        overlayStart.committed(install)
        guard install != nil else { return }
        overlayStartTimer.schedule(after: OverlayStartCheck.readyWithin) { @MainActor [weak self] in
            guard let self, !self.isClosed, let install = self.overlayStart.deadline(shown: self.isShownForHealth) else { return }
            self.overlayDidNotStart(install, why: "its page code did not answer in \(OverlayStartCheck.readyWithin.components.seconds) s")
        }
    }

    /// Page code spoke to the host: the document started.
    func overlayStartSpoke() {
        if overlayStart.spoke() { overlayStartTimer.cancel() }
    }

    /// The document's load failed or its process ended (`why`): true when that fell every page back
    /// to the bundle, so this one reloads from it now.
    func overlayStartFailed(_ why: String) -> Bool {
        guard let install = overlayStart.failed() else { return false }
        overlayStartTimer.cancel()
        return overlayDidNotStart(install, why: why)
    }

    @discardableResult
    private func overlayDidNotStart(_ install: WebDevOverride.OverlayInstall, why: String) -> Bool {
        WebDevOverride.overlayDidNotStart(install, page: healthLabel, why: why)
    }
}
