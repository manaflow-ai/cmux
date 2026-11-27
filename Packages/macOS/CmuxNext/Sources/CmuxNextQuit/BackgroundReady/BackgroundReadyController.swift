public import AppKit
public import CmuxNextActions
import CmuxNextCompat
import CmuxNextControl
public import CmuxNextDaemonService
import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextUpdater
import CmuxNextWakeups
import os

/// The background ready copy (`app.backgroundReady`, off by default; Leo 2026-11-17, ask-b2b0f899c1: "how can
/// we improve those? startup in background maybe?"): a Quit that cmux-background-ready says stays leaves the
/// process running hidden, its windows ordered out (or closed), Chromium still initialised, in background mode
/// (``BackgroundActivation``); the next open (Dock, Finder, a URL, Show cmux, a window appearing) brings back
/// exactly what was shown, with no launch. Every decision is the library's (``BackgroundReadyRules``); this
/// does the AppKit work. With the setting off nothing here acts: no quit stays, no launch starts hidden.
@MainActor
public final class BackgroundReadyController: BackgroundStay {
    /// What a stay hid, until the next show.
    struct Hidden {
        let plan: BackgroundReadyRules.HiddenPlan
        /// Keep Windows: the windows ordered out, front to back, and the one that had the keys.
        var kept: [NSWindow] = []
        var key: NSWindow?
        /// Close Windows: the windows closed as a person closes them, front to back.
        var closed: [String] = []
        /// The choice of the quit that hid cmux: Quit Completely ends with it.
        let choice: QuitSessionsChoice
    }

    private weak var host: (any BackgroundReadyHost)?
    /// Hidden by this feature: nil while cmux shows.
    private(set) var hidden: Hidden?
    /// A login start made no window and no Chromium warm-up yet: the first show restores and warms.
    public private(set) var defersRestore = false
    public private(set) var chromiumWarmupDeferred = false
    /// The next quit is Quit Completely.
    private var quitsCompletely = false
    /// The front chat of the show in progress has yet to paint (`reopen.agent_pane.painted`).
    private var awaitsChatPaint = false
    private var listensForPaint = false
    private var settingFollow: Task<Void, Never>?
    /// The updater's staged-update moment (its flow reaching Update Ready), followed while hidden.
    private var stagedWatch: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.background-ready")
    /// The stay's saves, each held to its limit; their ends are marked on every stay.
    private lazy var saves = QuitStepLimiter(mark: { BackgroundReadyMarks.each("background_ready.\($0)") })

    /// Joins `host`'s background mode (``BackgroundActivation/stay``).
    public init(host: any BackgroundReadyHost) {
        self.host = host
        host.background.stay = self
        // Offered (the app menu, the menu bar items, the palette) only while the setting is on.
        host.registry.bind("quitCompletely", isEnabled: { [weak self] in self?.offersQuitCompletely ?? false }) { [weak self] in
            self?.quitCompletely()
        }
    }

    /// `app.backgroundReady`, as the library reads it.
    var mode: BackgroundReadyRules.Mode {
        BackgroundReadyRules.mode(host?.settings.map { BackgroundReadySetting.value(in: $0.snapshot.root) } ?? BackgroundReadySetting.fallback)
    }

    /// Hidden by this feature (Keep Windows' windows still have their controllers).
    public var isHidden: Bool { hidden != nil }

    /// Quit Completely is offered (the app menu's Option-alternate, the menu bar items) while the setting keeps a
    /// hidden copy (After Quit, After Quit and at Login; not Off, not Warm at Login, which keeps nothing running).
    public var offersQuitCompletely: Bool { BackgroundReadyRules.offersQuitCompletely(mode) }

    // MARK: BackgroundStay

    public var holdsBackground: Bool { hidden != nil || defersRestore }
    public var quitItems: [ActionID] { offersQuitCompletely ? ["quit", "quitCompletely"] : ["quit"] }
    public func backgroundDidLeave() { showIfHidden("window appears") }

    // MARK: Quit

    /// The updater installs a staged update when this process exits (or is installing one now).
    private var updateInstallsOnQuit: Bool {
        guard let updater = host?.updater else { return false }
        let flow = updater.flow
        return flow.installRequested || flow.phase == .installing || (flow.phase.isReady && updater.preferences.installOnQuit)
    }

    /// A quit began: whether it is Quit Completely (asked for, or any quit while hidden, the menu bar item's
    /// Quit). Read once per quit, as it starts.
    public func quitBegan() -> Bool {
        defer { quitsCompletely = false }
        return quitsCompletely || isHidden || defersRestore
    }

    /// Whether the quit from `origin` stays hidden (``QuitCoordinator``, after its unsaved step).
    public func staysHidden(after origin: QuitOrigin, completely: Bool) -> Bool {
        BackgroundReadyRules.staysHidden(mode, origin: origin, updateInstallsOnQuit: updateInstallsOnQuit, quitCompletely: completely)
    }

    /// The stay: the quit's saves that end nothing, then the plan's window work and background mode. A cmux
    /// hidden already stays as it is.
    public func hide(choice: QuitSessionsChoice) async {
        guard let host, hidden == nil else { return }
        host.backgroundReadyCaptureGeometry()
        let steps: [(String, @MainActor @Sendable () async -> Void)] = [
            ("window_records", { await host.backgroundReadySaveWindowRecords() }), ("sidebar", { await host.backgroundReadySaveSidebar() }),
            ("home_cache", { await host.backgroundReadySaveHomeCache() }), ("launch_record", { await host.backgroundReadySaveLaunchRecord() }),
        ]
        for (name, save) in steps { await saves.run(name, limit: .seconds(1), save) }
        let override = ProcessInfo.processInfo.environment[BackgroundReadyRules.planOverrideVariable]
        let plan = BackgroundReadyRules.hiddenPlan(mode, startedAtLogin: false, override: override)
        var state = Hidden(plan: plan, choice: choice)
        let shown = Self.frontToBack(host.backgroundReadyShownWindows)
        switch plan {
        case .keepWindows:
            state.kept = shown
            state.key = shown.first { $0.isKeyWindow }
            hidden = state
            for window in shown { window.orderOut(nil) }
        case .closeWindows, .nativeOnly:
            // Chromium stays initialised (it cannot start again in this process): only the windows go.
            state.closed = shown.compactMap(host.backgroundReadyWindowID)
            hidden = state
            for window in shown { window.close() }
        }
        logger.notice("hidden plan=\(String(describing: plan), privacy: .public) windows=\(shown.count, privacy: .public)")
        BackgroundReadyMarks.each("background_ready.hidden")
        host.background.windowsDidChange()
        followStagedUpdates()
    }

    /// `windows` in the window server's order, front first.
    private static func frontToBack(_ windows: [NSWindow]) -> [NSWindow] {
        let ordered = NSApp.orderedWindows
        return windows.sorted { (ordered.firstIndex(of: $0) ?? .max) < (ordered.firstIndex(of: $1) ?? .max) }
    }

    /// Quit Completely: ends the process, the hidden one too, with the choice of the quit that hid it.
    public func quitCompletely() {
        quitsCompletely = true
        host?.backgroundReadyRequestQuit(.explicit(hidden?.choice ?? .keep))
    }

    // MARK: Show

    /// Shows what the stay hid, when hidden by this feature; false (nothing done) otherwise. Every way back
    /// (Dock, Finder, a URL, Show cmux, a window appearing) calls it first.
    @discardableResult
    public func showIfHidden(_ reason: String) -> Bool {
        guard let host else { return false }
        if defersRestore { return startDeferred(reason, host) }
        guard let state = hidden else { return false }
        hidden = nil
        stopFollowingStagedUpdates()
        BackgroundReadyMarks.reopen("requested")
        logger.notice("show (\(reason, privacy: .public)) plan=\(String(describing: state.plan), privacy: .public)")
        host.background.windowWillAppear(activates: true)
        switch state.plan {
        case .keepWindows:
            // A window whose workspaces ended while hidden is gone: only the live ones come back.
            let kept = state.kept.filter { host.backgroundReadyWindowID($0) != nil }
            for window in kept.reversed() { WindowActivation.show(window, .bringForward) }
            if let front = state.key.flatMap({ key in kept.first { $0 === key } }) ?? kept.first { WindowActivation.show(front, .focus) }
            if kept.isEmpty { host.backgroundReadyReopenOrCreate() }
        case .closeWindows, .nativeOnly:
            for id in state.closed.reversed() { host.backgroundReadyReopen(windowID: id) }
            if state.closed.isEmpty { host.backgroundReadyReopenOrCreate() }
        }
        markShown(host)
        return true
    }

    /// The shown window's marks: on screen now, its next committed frame, usable, and its chat's paint.
    private func markShown(_ host: any BackgroundReadyHost) {
        BackgroundReadyMarks.reopen("window_shown")
        let chatPainted = host.backgroundReadyFrontChatPainted
        awaitsChatPaint = chatPainted == false
        if awaitsChatPaint, !listensForPaint {
            listensForPaint = true
            host.backgroundReadyListenForLaunchMarks { [weak self] name in
                guard name == "agent_pane.painted", let self else { return }
                MainDelivery().run { [weak self] in self?.chatPainted() }
            }
        }
        CATransaction.setMainCompletion { [weak self, weak host] in
            BackgroundReadyMarks.reopen("first_frame_committed")
            if host?.backgroundReadyFrontIsKey == true { BackgroundReadyMarks.reopen("window_usable") }
            if chatPainted == true, self?.awaitsChatPaint == false { BackgroundReadyMarks.reopen("agent_pane.painted") }
        }
    }

    /// A chat painted: the front chat of the show in progress, when one waits.
    func chatPainted() {
        guard awaitsChatPaint else { return }
        awaitsChatPaint = false
        BackgroundReadyMarks.reopen("agent_pane.painted")
    }

    // MARK: Launch

    /// What this launch does under `snapshot`'s setting, `launchedAsLoginItem` read from the launch's open-application
    /// Apple event (``BackgroundReadyLoginItem/launchedAsLoginItem(_:)``). A login start: no window, no launch window, no Chromium
    /// warm-up, background mode at once, and the first show restores. A login start the setting no longer
    /// wants unregisters the login item and quits completely: it throws, so the launch goes no further.
    public func launch(_ snapshot: CmuxConfigSnapshot, launchedAsLoginItem: Bool) throws {
        let mode = BackgroundReadyRules.mode(BackgroundReadySetting.value(in: snapshot.root))
        switch BackgroundReadyRules.atLaunch(mode, launchedAsLoginItem: launchedAsLoginItem) {
        case .normal:
            return
        case .startHidden:
            let plan = BackgroundReadyRules.hiddenPlan(mode, startedAtLogin: true, override: ProcessInfo.processInfo.environment[BackgroundReadyRules.planOverrideVariable])
            defersRestore = true
            chromiumWarmupDeferred = !BackgroundReadyRules.startsChromiumWarmup(plan, shown: false)
            BackgroundReadyMarks.each("background_ready.started_hidden")
            host?.background.enterNow()
            followStagedUpdates()
        case .exitAndUnregister:
            logger.notice("login start with app.backgroundReady not at login: unregistering and quitting")
            BackgroundReadyLoginItem.apply(registers: false)
            quitCompletely()
            throw CancellationError()
        }
    }

    private func startDeferred(_ reason: String, _ host: any BackgroundReadyHost) -> Bool {
        defersRestore = false
        stopFollowingStagedUpdates()
        BackgroundReadyMarks.reopen("requested")
        logger.notice("first show of a hidden start (\(reason, privacy: .public))")
        host.background.windowWillAppear(activates: true)
        host.backgroundReadyRestore()
        let plan = BackgroundReadyRules.hiddenPlan(mode, startedAtLogin: true, override: ProcessInfo.processInfo.environment[BackgroundReadyRules.planOverrideVariable])
        if chromiumWarmupDeferred, BackgroundReadyRules.startsChromiumWarmup(plan, shown: true), !host.backgroundReadyIsSafeRestart {
            chromiumWarmupDeferred = false
            host.backgroundReadyStartChromiumWarmup()
        }
        markShown(host)
        return true
    }

    // MARK: Updates

    /// The updater staged an update (or cmux just hid with one staged): a hidden cmux quits for good so
    /// Sparkle installs it. Never blocks the install. Staged counts only an update this exit installs: with
    /// `updates.installOnQuit` off the quit cancels Sparkle's installer, so exiting would install nothing.
    public func exitIfUpdateStaged() {
        guard let updater = host?.updater else { return }
        let staged = updater.flow.phase.isReady && updater.preferences.installOnQuit
        guard BackgroundReadyRules.exitsForUpdate(mode, hidden: holdsBackground, updateStaged: staged) else { return }
        logger.notice("an update is staged while hidden: quitting for good so it installs")
        quitCompletely()
    }

    /// While hidden, each time the updater stages an update (its flow reaches Update Ready): exit for it.
    private func followStagedUpdates() {
        stagedWatch?.cancel()
        guard let updater = host?.updater else { return }
        // task-owner: one hidden stretch; cancelled at the show.
        stagedWatch = Task { [weak self] in
            for await ready in ObservationStream({ updater.flow.phase.isReady }) where ready {
                self?.exitIfUpdateStaged()
            }
        }
    }

    private func stopFollowingStagedUpdates() {
        stagedWatch?.cancel()
        stagedWatch = nil
    }

    // MARK: Setting

    /// Each time the setting changes (and at the first load): Quit Completely joins the app menu (Quit's
    /// Option-alternate) and the menu bar item's menu while it is on, and the login item is registered while
    /// the library says so, and so is the login-time pre-read agent (Warm at Login) (`registersLoginItem` false,
    /// an agent-launched build, leaves login items and the agent alone).
    public func follow(_ settings: SettingsController, registersLoginItem: Bool) {
        settingFollow?.cancel()
        // task-owner: replaced by the next follow; ends with the app's services.
        settingFollow = Task { [weak self, weak settings] in
            guard let settings else { return }
            await settings.waitForLoad(atLeast: 1)
            for await value in ObservationStream({ BackgroundReadySetting.value(in: settings.snapshot.root) }) {
                let mode = BackgroundReadyRules.mode(value)
                guard let self, let host = self.host else { return }
                let offers = BackgroundReadyRules.offersQuitCompletely(mode)
                BackgroundReadyMenu.place(registry: host.registry, shown: offers)
                host.menuBarExtra.offersQuitCompletely = offers
                if registersLoginItem {
                    BackgroundReadyLoginItem.apply(registers: BackgroundReadyRules.registersLoginItem(mode))
                    self.applyPrereadAgent(BackgroundReadyRules.registersPrereadAgent(mode))
                }
            }
        }
    }

    /// Registers or unregisters the login-time pre-read agent (``BackgroundReadyPrereadAgent``) and logs what changed.
    private func applyPrereadAgent(_ registers: Bool) {
        let outcome = BackgroundReadyPrereadAgent.app().apply(registers: registers)
        switch outcome {
        case .unchanged: break
        case .failed(let reason):
            logger.error("pre-read agent \(registers ? "register" : "unregister", privacy: .public) failed: \(reason, privacy: .public)")
        default: logger.notice("pre-read agent: \(String(describing: outcome), privacy: .public)")
        }
    }
}
