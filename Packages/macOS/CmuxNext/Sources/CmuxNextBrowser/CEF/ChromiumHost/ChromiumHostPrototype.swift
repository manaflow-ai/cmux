#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// The Chromium host app prototype as `debug.chromium_host` drives it
/// (Debug and bench builds, the feature `cefHelperHost` on): one
/// ``ChromiumHostSession`` shown over a pane's content view.
/// plans/cmux-next/cef-helper-app-DESIGN.md.
///
/// The host lives no longer than its pane and its switch: the session
/// closes (`quit`, then SIGKILL at the quit limit) when the page view leaves
/// its window (the pane closed or moved out of every window) and when the
/// switch goes off (its Debug Settings override `browserHost.helper` turned
/// off). A later `open` starts a new host. With an idle deadline (`chromiumHostIdleExit`), `detach` makes the page hidden
/// instead: out of every window but still owned, its host quits at the
/// deadline, and the next `open` starts a new one. (A parked workspace stays
/// in its window, so its page stays live.) The stand-in of a restarted host is
/// the page background only: the host's pixels are a remote layer
/// (CALayerHost) that cmux cannot capture, and the wire has no snapshot yet.
@MainActor
public final class ChromiumHostPrototype {
    private var session: ChromiumHostSession?
    private let makeConfiguration: () -> ChromiumHostConfiguration?
    /// The session over a configuration and idle deadline (tests pass one with a stand-in launcher).
    private let makeSession: @MainActor (ChromiumHostConfiguration, ChromiumHostIdleExit?) -> ChromiumHostSession
    /// The session's idle deadline (`chromiumHostIdleExit`'s `idleExitAfter`); nil keeps the host.
    private let idleExitAfter: Duration?
    /// The app's deadline scheduler the idle deadline waits on.
    private let deadlines: MainDeadlineScheduler
    /// ``open(_:over:focus:)`` moves the page view to another pane: AppKit may
    /// take it out of the window on the way, which does not end the host.
    private var movingPageView = false
    /// ``detach()`` takes the page view out of its pane to hide it, not to end its host.
    private var hidingPageView = false
    /// The session has an idle deadline: a detached page waits for it instead of closing.
    private var sessionHasIdleExit = false

    /// Whether the host is on: `cefHelperHost` with its Debug Settings override, read with
    /// Observation tracking (off by default: every Chromium tab runs in process; only
    /// `debug.chromium_host` uses the host, and only with it on).
    private let isOn: @MainActor () -> Bool
    private let mainWork: MainWorkScheduler
    /// Follows ``isOn`` once a host started (``watchSwitch()``).
    private var switchWatch: FrameObservation<Bool>?

    /// - Parameters:
    ///   - makeConfiguration: the host app of this build, or nil when it has none.
    ///   - isOn: The host's switch, from the composition root (`ChromiumHostSwitch`; tests pass their own).
    ///   - mainWork: The app's one main-thread scheduler: the switch going off closes the host on it.
    ///   - deadlines: The app's deadline scheduler: the idle deadline waits on it.
    ///   - idleExitAfter: How long a host runs with its page in no window before it quits
    ///     (`chromiumHostIdleExit`, resolved by the composition root); nil keeps it running.
    ///   - inputPresented: Takes the host's presentation report of each input (the app's input latency tracker,
    ///     task p04-input-066).
    ///   - reportsInputPresented: Takes whether the current host sends those reports (the tracker's
    ///     `pagesReportPresentation`).
    public convenience init(makeConfiguration: @escaping () -> ChromiumHostConfiguration?, isOn: @escaping @MainActor () -> Bool,
                            mainWork: MainWorkScheduler, deadlines: MainDeadlineScheduler, idleExitAfter: Duration? = nil,
                            inputPresented: @escaping ChromiumHostSession.InputPresented = { _, _ in },
                            reportsInputPresented: @escaping ChromiumHostSession.ReportsInputPresented = { _ in }) {
        // No picture source: the stand-in is the page background (see the type's comment).
        self.init(makeConfiguration: makeConfiguration, isOn: isOn, mainWork: mainWork, deadlines: deadlines,
                  idleExitAfter: idleExitAfter) {
            ChromiumHostSession(configuration: $0, idleExit: $1, inputPresented: inputPresented,
                                reportsInputPresented: reportsInputPresented)
        }
    }

    init(makeConfiguration: @escaping () -> ChromiumHostConfiguration?, isOn: @escaping @MainActor () -> Bool, mainWork: MainWorkScheduler,
         deadlines: MainDeadlineScheduler, idleExitAfter: Duration? = nil,
         makeSession: @escaping @MainActor (ChromiumHostConfiguration, ChromiumHostIdleExit?) -> ChromiumHostSession) {
        self.makeConfiguration = makeConfiguration
        self.makeSession = makeSession
        self.isOn = isOn
        self.mainWork = mainWork
        self.deadlines = deadlines
        self.idleExitAfter = idleExitAfter
    }

    /// The bundled host of this app (`Contents/MacOS/<App> Chromium Host`), its data under
    /// `<Application Support>/<bundle id>/ChromiumHost`.
    public static func bundledConfiguration(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> ChromiumHostConfiguration? {
        guard let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identifier = bundle.bundleIdentifier ?? "cmux"
        return ChromiumHostConfiguration.bundled(in: layout,
                                                 rootCache: ChromiumHostConfiguration.rootCache(applicationSupport: support, bundleIdentifier: identifier),
                                                 bundleIdentifier: identifier, environment: environment)
    }

    /// The `idle_exit_s` a `debug.chromium_host` open may ask for: the bounds of the feature's
    /// `idleExitAfter`, down to 1 s so a bench need not wait for the feature's 10 s floor.
    public static let debugIdleExitSeconds: ClosedRange<Double> = 1...3600

    /// `debug.chromium_host` {op: open {url, pane?, focus?, idle_exit_s?} | detach | close | kill | report}:
    /// `container` is the pane content view `open` shows the page over; `focus`
    /// (false unless the call asks) makes the page first responder; `idleExitSeconds`
    /// (`idle_exit_s`, within ``debugIdleExitSeconds``) replaces the idle deadline of the
    /// session the first `open` makes.
    public func handle(op: String?, url: String?, over container: NSView?, focus: Bool,
                       idleExitSeconds: Double? = nil) -> [String: Any] {
        switch op {
        case "open":
            guard let container else { return ["error": "no pane"] }
            var idleExit: Duration?
            if let seconds = idleExitSeconds {
                guard Self.debugIdleExitSeconds.contains(seconds) else {
                    return ["error": "idle_exit_s must be within \(Self.debugIdleExitSeconds)"]
                }
                idleExit = .seconds(seconds)
            }
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
        guard isOn() else { return ["error": "cefHelperHost is off"] }
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
            session = makeSession(configuration, idle)
            sessionHasIdleExit = idle != nil
            // A closed pane (or one moved out of every window) ends the host at once; only a
            // detached page waits for the idle deadline.
            session.view.onLeftWindow = { [weak self, weak session] in
                guard let self, !self.movingPageView, !self.hidingPageView else { return }
                session?.close()
            }
            self.session = session
            watchSwitch()
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
        hidingPageView = sessionHasIdleExit
        session?.view.removeFromSuperview()
        hidingPageView = false
        return report
    }

    /// Ends the host on purpose and removes its page view.
    public func close() -> [String: Any] {
        session?.close()
        session?.view.removeFromSuperview()
        return report
    }

    /// Closes the host when the switch goes off. Started with the first session, for the
    /// prototype's life: `debug.chromium_host` drives it, so it is automation work and needs no frame.
    private func watchSwitch() {
        guard switchWatch == nil else { return }
        let watch = FrameObservation(owner: "browser.chromiumHost.switch", delivery: .automation, on: mainWork, track: isOn) { [weak self] on in
            if !on { _ = self?.close() }
        }
        switchWatch = watch
        if !watch.value { _ = close() }
    }

    /// SIGKILL to the host (the crash check).
    public func kill() -> [String: Any] {
        ["killed_pid": Int(session?.killHost() ?? 0)]
    }

    public var report: [String: Any] {
        var fields = session?.report ?? ["phase": "none"]
        fields["enabled"] = isOn()
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
