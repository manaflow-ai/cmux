import Foundation

/// Whether a document served from an overlay install started (Leo, 2026-11-14: "I want people to
/// not accidentally soft lock themselves and like have good recovery options or whatever"). From
/// commit until its page code first speaks to the host (any bridge message: every page boots through
/// the page client, which beats `cmux.page.heartbeat` at once while shown), a failed load, an ended
/// process, silence for ``readyWithin`` after its document loaded, or a document still loading after
/// ``loadWithin``, while shown, means the install did not start, and the app falls back to the bundled
/// pages (``WebDevOverride/overlayDidNotStart(_:page:why:)``).
///
/// Slow is not broken: the silence counts from the document's load, not its commit. Every module
/// script has run by then, so a page that works has spoken. On a loaded Mac a document takes 44 s
/// and more to load (2026-11-22 06:41:33Z, `documentStarted()`), and an overlay's files all go through the
/// host (``PageWebView/chromiumResource(_:range:)``): counted from commit, a healthy onboarding page
/// read as a broken install and turned the layer off ("Onboarding did not start: its page code did
/// not answer in 20 s", cmux#50470's layer in a side copy on a fleet Mac, 2026-11-22).
public nonisolated struct OverlayStartCheck: Equatable, Sendable {
    /// How long a shown document from an overlay has to speak once it loaded. Generous: a page that
    /// works speaks before or within a frame or two of its load.
    public static let readyWithin: Duration = .seconds(20)
    /// How long a shown document from an overlay may take to load at all: the bound on a load that
    /// never ends (a file the overlay never answers). Well past the slowest healthy loads seen.
    public static let loadWithin: Duration = .seconds(180)

    /// The install the current document came from, until it spoke; nil when it came from elsewhere.
    public private(set) var watching: WebDevOverride.OverlayInstall?

    public init() {}

    /// Whether the watched document loaded: its silence counts from then (``readyWithin``).
    public private(set) var loaded = false

    /// A new document committed, served from `install` (nil: not from an overlay).
    public mutating func committed(_ install: WebDevOverride.OverlayInstall?) {
        watching = install
        loaded = false
    }

    /// The document loaded: true when it is still watched, so its ``readyWithin`` starts now.
    public mutating func documentLoaded() -> Bool {
        guard watching != nil else { return false }
        loaded = true
        return true
    }

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

    /// A document committed: watch its start when an overlay served it. Until it loads, only a
    /// load that never ends (``OverlayStartCheck/loadWithin``) counts against it.
    func watchOverlayStart() {
        overlayStartTimer.cancel()
        let install = overlayInstallServingDocument
        overlayStart.committed(install)
        guard install != nil else { return }
        scheduleOverlayStartDeadline(after: OverlayStartCheck.loadWithin,
                                     why: "its document did not load in \(OverlayStartCheck.loadWithin.components.seconds) s")
    }

    /// The document loaded: its page code has run, so its silence counts from now.
    func overlayDocumentLoaded() {
        guard overlayStart.documentLoaded() else { return }
        scheduleOverlayStartDeadline(after: OverlayStartCheck.readyWithin,
                                     why: "its page code did not answer in \(OverlayStartCheck.readyWithin.components.seconds) s after it loaded")
    }

    private func scheduleOverlayStartDeadline(after delay: Duration, why: String) {
        overlayStartTimer.cancel()
        overlayStartTimer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, !self.isClosed, let install = self.overlayStart.deadline(shown: self.isShownForHealth) else { return }
            self.overlayDidNotStart(install, why: why)
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
