#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// The Chromium host app prototype as `debug.chromium_host` drives it
/// (Debug and bench builds, `browserHost.helper` on): one
/// ``ChromiumHostSession`` shown over a pane's content view.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
///
/// The host lives no longer than its pane and the tunable: the session
/// closes (`quit`, then SIGKILL at the quit limit) when the page view leaves
/// its window (the pane closed or moved out of every window) and when
/// `browserHost.helper` goes off. A later `open` starts a new host. With an
/// idle deadline (`chromiumHostIdleExit`) a page view out of every window is a
/// hidden page instead: its host quits at the deadline, and the next `open`
/// (or the view back in a window) starts a new one.
@MainActor
public final class ChromiumHostPrototype {
    private var session: ChromiumHostSession?
    private let makeConfiguration: () -> ChromiumHostConfiguration?
    /// The session's idle deadline (`chromiumHostIdleExit`'s `idleExitAfter`); nil keeps the host.
    private let idleExitAfter: Duration?
    /// The app's deadline scheduler the idle deadline waits on.
    private let deadlines: MainDeadlineScheduler
    /// ``open(_:over:focus:)`` moves the page view to another pane: AppKit may
    /// take it out of the window on the way, which does not end the host.
    private var movingPageView = false

    /// The Debug Settings `browserHost.helper` is read from (off by default: every Chromium
    /// tab runs in process; only `debug.chromium_host` uses the host, and only with it on).
    private let tunables: TunableStore
    private let mainWork: MainWorkScheduler
    /// Follows `browserHost.helper` once a host started (``watchTunable()``).
    private var tunableWatch: FrameObservation<Bool>?

    /// - Parameters:
    ///   - makeConfiguration: the host app of this build, or nil when it has none.
    ///   - tunables: Debug Settings: the app's store, passed by the composition root (tests pass one of their own).
    ///   - mainWork: The app's one main-thread scheduler: a tunable change closes the host on it.
    ///   - deadlines: The app's deadline scheduler: the idle deadline waits on it.
    ///   - idleExitAfter: How long a host runs with its page in no window before it quits
    ///     (`chromiumHostIdleExit`, resolved by the composition root); nil keeps it running.
    public init(makeConfiguration: @escaping () -> ChromiumHostConfiguration?, tunables: TunableStore, mainWork: MainWorkScheduler,
                deadlines: MainDeadlineScheduler, idleExitAfter: Duration? = nil) {
        self.makeConfiguration = makeConfiguration
        self.tunables = tunables
        self.mainWork = mainWork
        self.deadlines = deadlines
        self.idleExitAfter = idleExitAfter
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

    /// `debug.chromium_host` {op: open {url, pane?, focus?, idle_exit_s?} | detach | close | kill | report}:
    /// `container` is the pane content view `open` shows the page over; `focus`
    /// (false unless the call asks) makes the page first responder; `idleExit`
    /// (`idle_exit_s`) replaces the idle deadline of the session the first `open` makes.
    public func handle(op: String?, url: String?, over container: NSView?, focus: Bool,
                       idleExit: Duration? = nil) -> [String: Any] {
        switch op {
        case "open":
            guard let container else { return ["error": "no pane"] }
            return open(url ?? "", over: container, focus: focus, idleExit: idleExit)
        case "detach": return detach()
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
    /// first responder of `window` when `focus`. A page whose host quit at its idle
    /// deadline starts a new one.
    public func open(_ url: String, over container: NSView, focus: Bool, idleExit: Duration? = nil) -> [String: Any] {
        guard BrowserHostTunables.helper.value(in: tunables) else { return ["error": "browserHost.helper is off"] }
        guard !url.isEmpty else { return ["error": "pass url"] }
        guard container.window != nil else { return ["error": "the pane is not in a window"] }
        let session: ChromiumHostSession
        if let existing = self.session {
            session = existing
        } else {
            guard let configuration = makeConfiguration() else {
                return ["error": "this build has no Chromium host app (Debug and bench builds with CEF only)"]
            }
            let idle = (idleExit ?? idleExitAfter).map { ChromiumHostIdleExit(after: $0, deadlines: deadlines) }
            session = ChromiumHostSession(configuration: configuration, idleExit: idle)
            if idle == nil {
                session.view.onLeftWindow = { [weak self, weak session] in
                    guard self?.movingPageView != true else { return }
                    session?.close()
                }
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

    /// Takes the page view out of its pane without ending the host: a hidden page, whose host
    /// quits at the idle deadline (and, with no deadline, at once, as a closed pane's).
    public func detach() -> [String: Any] {
        session?.view.removeFromSuperview()
        return report
    }

    /// Ends the host on purpose and removes its page view.
    public func close() -> [String: Any] {
        session?.close()
        session?.view.removeFromSuperview()
        return report
    }

    /// Closes the host when the tunable goes off. Started with the first session, for the
    /// prototype's life: `debug.chromium_host` drives it, so it is automation work and needs no frame.
    private func watchTunable() {
        guard tunableWatch == nil else { return }
        let watch = FrameObservation(owner: "browser.chromiumHost.tunable", delivery: .automation, on: mainWork) { [tunables] in
            BrowserHostTunables.helper.value(in: tunables)
        } onChange: { [weak self] on in
            if !on { _ = self?.close() }
        }
        tunableWatch = watch
        if !watch.value { _ = close() }
    }

    /// SIGKILL to the host (the crash check).
    public func kill() -> [String: Any] {
        ["killed_pid": Int(session?.killHost() ?? 0)]
    }

    public var report: [String: Any] {
        var fields = session?.report ?? ["phase": "none"]
        fields["tunable"] = BrowserHostTunables.helper.value(in: tunables)
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
