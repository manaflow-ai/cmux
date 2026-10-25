#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
public import AppKit
public import CmuxNextDesign
import Observation

/// The Chromium host app prototype as `debug.chromium_host` drives it
/// (DEBUG builds, `browserHost.helperPrototype` on): one
/// ``ChromiumHostSession`` shown over a pane's content view.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
///
/// The host lives no longer than its pane and the tunable: the session
/// closes (`quit`, then SIGKILL at the quit limit) when the page view leaves
/// its window (the pane closed or moved out of every window) and when
/// `browserHost.helperPrototype` goes off. A later `open` starts a new host.
@MainActor
public final class ChromiumHostPrototype {
    private var session: ChromiumHostSession?
    private let makeConfiguration: () -> ChromiumHostConfiguration?
    /// ``open(_:over:focus:)`` moves the page view to another pane: AppKit may
    /// take it out of the window on the way, which does not end the host.
    private var movingPageView = false

    /// The Debug Settings `browserHost.helperPrototype` is read from (off by default: every Chromium
    /// tab runs in process; only `debug.chromium_host` uses the host, and only with it on).
    private let tunables: TunableStore

    /// - Parameters:
    ///   - makeConfiguration: the host app of this build, or nil when it has none.
    ///   - tunables: Debug Settings (the app's own store; tests pass one of their own).
    public init(makeConfiguration: @escaping () -> ChromiumHostConfiguration?, tunables: TunableStore = .shared) {
        self.makeConfiguration = makeConfiguration
        self.tunables = tunables
    }

    /// The bundled host of this app (`Contents/MacOS/<App> Chromium Host`), its data under
    /// `<Application Support>/<bundle id>/ChromiumHost`.
    public static func bundledConfiguration(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                                            fileManager: FileManager = .default) -> ChromiumHostConfiguration? {
        guard let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment, fileManager: fileManager),
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identifier = bundle.bundleIdentifier ?? "cmux"
        return ChromiumHostConfiguration.bundled(in: layout, rootCache: support.appending(path: identifier).appending(path: "ChromiumHost"),
                                                 bundleIdentifier: identifier, environment: environment, fileManager: fileManager)
    }

    /// `debug.chromium_host` {op: open {url, pane?, focus?} | close | kill | report}:
    /// `container` is the pane content view `open` shows the page over; `focus`
    /// (false unless the call asks) makes the page first responder.
    public func handle(op: String?, url: String?, over container: NSView?, focus: Bool) -> [String: Any] {
        switch op {
        case "open":
            guard let container else { return ["error": "no pane"] }
            return open(url ?? "", over: container, focus: focus)
        case "close": return close()
        case "kill": return kill()
        default: return report
        }
    }

    /// `debug.chromium_host.measure` {op: ping {count} | input}; nil without a running host.
    public func measure(op: String?, count: Int?) async -> [String: Double]? {
        op == "ping" ? await ping(count: count ?? 200) : await inputStats()
    }

    /// Starts the host (or navigates it) and shows its page over `container`,
    /// first responder of `window` when `focus`.
    public func open(_ url: String, over container: NSView, focus: Bool) -> [String: Any] {
        guard BrowserHostTunables.helperPrototype.value(in: tunables) else { return ["error": "browserHost.helperPrototype is off"] }
        guard !url.isEmpty else { return ["error": "pass url"] }
        guard container.window != nil else { return ["error": "the pane is not in a window"] }
        let session: ChromiumHostSession
        if let existing = self.session {
            session = existing
        } else {
            guard let configuration = makeConfiguration() else {
                return ["error": "this build has no Chromium host app (Debug builds with CEF only)"]
            }
            session = ChromiumHostSession(configuration: configuration)
            session.view.onLeftWindow = { [weak self, weak session] in
                guard self?.movingPageView != true else { return }
                session?.close()
            }
            self.session = session
            watchTunable()
        }
        if session.view.superview !== container {
            session.view.frame = container.bounds
            movingPageView = true
            container.addSubview(session.view, positioned: .above, relativeTo: nil)
            movingPageView = false
        }
        guard session.open(url) else { return report }  // lastError says why
        if focus { container.window?.makeFirstResponder(session.view) }
        return report
    }

    /// Ends the host on purpose and removes its page view.
    public func close() -> [String: Any] {
        session?.close()
        session?.view.removeFromSuperview()
        return report
    }

    /// Closes the host when the tunable goes off; re-armed on every change of it.
    /// Armed once, with the session (which this prototype keeps for its life).
    private func watchTunable() {
        let on = withObservationTracking { BrowserHostTunables.helperPrototype.value(in: tunables) } onChange: {
            Task { @MainActor [weak self] in self?.watchTunable() }
        }
        if !on { _ = close() }
    }

    /// SIGKILL to the host (the crash check).
    public func kill() -> [String: Any] {
        ["killed_pid": Int(session?.killHost() ?? 0)]
    }

    public var report: [String: Any] {
        var fields = session?.report ?? ["phase": "none"]
        fields["tunable"] = BrowserHostTunables.helperPrototype.value(in: tunables)
        fields["app_pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        return fields
    }

    /// `count` wire round trips to the host's UI thread, as microsecond
    /// percentiles; nil without a running host.
    public func ping(count: Int) async -> [String: Double]? {
        guard let session else { return nil }
        let samples = await session.ping(count: min(max(count, 1), 10_000)).sorted()
        guard let last = samples.last else { return nil }
        func at(_ q: Double) -> Double { samples[Int((q * Double(samples.count - 1)).rounded())] }
        return ["count": Double(samples.count), "p50_us": at(0.5), "p95_us": at(0.95), "p99_us": at(0.99), "max_us": last]
    }

    /// The host's event-time-to-dispatch percentiles; nil without a running host.
    public func inputStats() async -> [String: Double]? {
        guard let stats = await session?.hostInputStats() else { return nil }
        return stats.mapValues(Double.init)
    }
}
#endif
