import CmuxNextCompat

/// cmux's watch on the Chromium Host's UI thread (task p01-process-084 of
/// plans/cmux-next/chrome-parity/p01-process.md, feature `chromiumHostHangBanner`).
///
/// The host acks input when its UI thread dispatches it (`kOpInputDispatched`, not the renderer's
/// ack), and the remote shim counts those acks against the seqs it gives the input ring's writer
/// (`cmux_remote_shim_set_host_watch`). This monitor arms one deadline only while input waits and
/// a hosted page shows: no input waiting, no timer, so an idle cmux wakes no more than before. When
/// the host dispatched nothing for ``busyAfter`` it shows "Chromium is busy" with Wait and Reload
/// Chromium (``isBusy``). Chrome's hang monitor works the same way per renderer
/// (`RenderWidgetHostImpl::StartInputEventAckTimeout`, `StopInputEventAckTimeout` once nothing is
/// in flight and on `WasHidden`, `RestartInputEventAckTimeoutIfNecessary` on an ack, Wait and
/// `WasShown`; content/browser/renderer_host/render_widget_host_impl.cc), with a 15 s delay
/// (`kHungRendererDelay`) because a renderer's hang freezes one tab; a host UI-thread stall
/// freezes every page, so this one says so after 2 s (p01-process.md design item 7). The restart
/// on an ack is lazy, as Chrome's `TimeoutMonitor` restarts (content/browser/renderer_host/input/
/// timeout_monitor.cc): an ack only records when the host last worked, and a deadline that fires
/// before 2 s have passed since then arms itself again for the rest.
///
/// The host's own UI hangs of 250 ms or more come here too (``onHang``) and go to cmux's hang
/// reports, tagged as the host's.
final class ChromiumHostHangMonitor {
    /// No dispatch this long with input waiting: the host's UI thread is busy.
    static let busyAfter: Duration = .seconds(2)
    /// The deadline fires at most this long after ``busyAfter`` (the banner shows at 2000 to 2050 ms).
    static let leeway: Duration = .milliseconds(50)

    /// The banner shows: input has waited ``busyAfter`` for the host while a page showed.
    private(set) var isBusy = false
    /// The deadline is armed.
    private(set) var isArmed = false
    /// Times the banner showed, how long the host had dispatched none of the waiting input when it
    /// last did (``busyAfter`` plus the deadline's lateness), and the host's UI hangs heard
    /// (`debug.cef` `host_hang`).
    private(set) var busyCount = 0
    private(set) var lastBusyAfter: Duration?
    private(set) var hangCount = 0
    /// Each change of ``isBusy``.
    var onBusyChange: ((Bool) -> Void)?
    /// Each UI hang the host reported.
    var onHang: ((ChromiumHostHang) -> Void)?
    /// Ends the host so it starts again (the banner's Reload Chromium); nil offers only Wait.
    var onReload: (() -> Void)?

    private let deadline: any ChromiumHostBusyDeadline
    private let now: () -> ContinuousClock.Instant
    /// Input waits for the host's dispatch.
    private var waiting = false
    /// Since when the host has dispatched none of the waiting input: the first waiting input, its
    /// last ack, the person's Wait or the first page shown since.
    private var stalledSince: ContinuousClock.Instant?
    /// The hosted pages that show now (``pageShown(_:_:)``).
    private var shownPages: Set<ObjectIdentifier> = []
    /// This monitor's entry for the remote shim's host watch callback (``token()``).
    private var registration: ChromiumHostHangMonitorRegistration?

    init(deadline: any ChromiumHostBusyDeadline, now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.deadline = deadline
        self.now = now
    }

    /// The Reload Chromium button shows.
    var canReload: Bool { onReload != nil }

    // MARK: The remote shim's host watch

    /// Input the host has not dispatched: the first seq waits.
    func inputOutstanding() {
        waiting = true
        stalledSince = now()
        arm()
    }

    /// The host dispatched input and later input still waits: it works, so a banner goes and the
    /// wait starts again from now.
    func inputProgress() {
        guard waiting else { return }
        stalledSince = now()
        setBusy(false)
        arm()
    }

    /// The host dispatched every seq written, or went away with them: no deadline.
    func inputSettled() {
        waiting = false
        stalledSince = nil
        disarm()
        setBusy(false)
    }

    /// A UI hang the host measured.
    func hostHang(_ hang: ChromiumHostHang) {
        hangCount += 1
        onHang?(hang)
    }

    // MARK: The person and the pages

    /// The banner's Wait: it goes, and the host gets ``busyAfter`` again.
    func keepWaiting() {
        setBusy(false)
        guard waiting else { return }
        stalledSince = now()
        arm()
    }

    /// The banner's Reload Chromium: the host ends and the supervisor starts a new one.
    func reload() {
        inputSettled()
        onReload?()
    }

    /// `page` (a hosted page view) shows or stops showing. With no page shown there is no deadline
    /// and no banner; the first page shown again gives waiting input ``busyAfter`` from then.
    func pageShown(_ page: ObjectIdentifier, _ shown: Bool) {
        let wasShown = !shownPages.isEmpty
        if shown { shownPages.insert(page) } else { shownPages.remove(page) }
        let isShown = !shownPages.isEmpty
        guard isShown != wasShown else { return }
        if isShown {
            if waiting { stalledSince = now() }
            arm()
        } else {
            disarm()
            setBusy(false)
        }
    }

    /// A hosted page shows.
    var isShown: Bool { !shownPages.isEmpty }

    // MARK: The deadline

    /// Arms the deadline for what is left of ``busyAfter`` since ``stalledSince``, while input waits,
    /// a page shows and no banner shows. One deadline at most: an armed one stays (lazy restart).
    private func arm() {
        guard waiting, isShown, !isBusy, !isArmed, let stalledSince else { return }
        isArmed = true
        let left = max(stalledSince + Self.busyAfter - now(), .zero)
        deadline.schedule(after: left) { [weak self] in self?.fired() }
    }

    private func disarm() {
        guard isArmed else { return }
        isArmed = false
        deadline.cancel()
    }

    /// The deadline: busy when the host has dispatched nothing since ``busyAfter`` ago, otherwise
    /// armed again for the rest.
    private func fired() {
        isArmed = false
        guard waiting, isShown, let stalledSince else { return }
        let stalled = now() - stalledSince
        if stalled >= Self.busyAfter {
            busyCount += 1
            lastBusyAfter = stalled
            setBusy(true)
        } else {
            arm()
        }
    }

    private func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        onBusyChange?(busy)
    }

    /// The context `cmux_remote_shim_set_host_watch` gets for this monitor, made once; it goes with it.
    func token() throws(CallbackRegistryError) -> CallbackToken {
        if let registration { return registration.token }
        let made = try ChromiumHostHangMonitorRegistration(self)
        registration = made
        return made.token
    }

    /// One change of the remote shim's host watch (`cmux_remote_host_watch_event`, remote_shim_runtime.h).
    func hostWatch(event: Int32, a: Int64, b: Int64) {
        switch event {
        case Self.inputOutstandingEvent: inputOutstanding()
        case Self.inputProgressEvent: inputProgress()
        case Self.inputSettledEvent: inputSettled()
        case Self.hostHangEvent: hostHang(ChromiumHostHang(durationNanos: a, flags: b))
        default: break
        }
    }

    // `cmux_remote_host_watch_event` (remote_shim_runtime.h).
    nonisolated static let inputOutstandingEvent: Int32 = 0
    nonisolated static let inputProgressEvent: Int32 = 1
    nonisolated static let inputSettledEvent: Int32 = 2
    nonisolated static let hostHangEvent: Int32 = 3

    /// C entry of the host watch: runs on the main thread (remote_shim_runtime.h,
    /// `cmux_remote_host_watch_fn`) with the monitor's token as its context.
    static let hostWatchCallback: CEFRemoteShim.HostWatchFn = { context, event, a, b in
        // A token whose monitor is gone finds nothing (the registry counts it).
        guard let monitor = unsafe ChromiumHostHangMonitorRegistration.monitors.target(forContext: context) else { return }
        MainActor.assumeIsolated { // main-proof: cmux_remote_host_watch_fn runs on the main thread (remote_shim_runtime.h)
            monitor.hostWatch(event: event, a: a, b: b)
        }
    }
}

/// A monitor's entry in ``monitors`` for as long as the monitor holds it: the token is the context the
/// remote shim's host watch callback gets, so a frame after the monitor is gone finds nothing, as
/// ``CEFReplySinkRegistration`` does for the reply table.
nonisolated final class ChromiumHostHangMonitorRegistration: Sendable {
    /// The live monitors by token: one per runtime, a few in tests.
    static let monitors = CallbackRegistry<ChromiumHostHangMonitor>(capacity: 8)
    let token: CallbackToken

    init(_ monitor: ChromiumHostHangMonitor) throws(CallbackRegistryError) {
        token = try Self.monitors.register(monitor)
    }

    deinit {
        Self.monitors.unregister(token)
    }
}
