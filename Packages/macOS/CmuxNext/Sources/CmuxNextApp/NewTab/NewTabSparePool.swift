import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups

/// Instant new tab (plans/cmux-next/new-tab.md section 2): ONE prewarmed new
/// tab page per app (Lawrence: "a pool of 1"), loaded, rendered and connected
/// to acpmux, parked out of sight in the key main window. When another main
/// window becomes key the parked page moves there (a reparent, no reload).
/// Opening the new tab page in any window adopts it in the same main-actor
/// turn (no load, no React mount on the open path); the next spare starts
/// once input has been quiet for ``idleInput``, so making a web view never
/// lands in the user's typing. The spare waits at the size of the pane
/// content Cmd-T fills (the target window's focused pane), refitted when a
/// pane there changes size or focus, so the adoption changes no size: WebKit
/// shows it at once at its final layout (hqacp-v2: a page parked at the
/// window's width showed for ~40 ms at that width after Cmd-T). Memory pressure drops the spare. A spare
/// exists while the new tab page is likely: a person's Cmd-T always opens it.
@MainActor
final class NewTabSparePool {
    /// One adoption, for `debug.new_tab` (timing test, section 2.3).
    struct Opening {
        var spare: Bool
        /// The spare was parked in another window than the one it opened in.
        var crossWindow: Bool
        /// Main-thread time from the open action to the page in its pane.
        var milliseconds: Double
        /// The spare waited at another size than its pane's: the adoption resized it, and WebKit
        /// showed it at the old size until it laid it out again (the hqacp-v2 flash).
        var refit = false
    }

    static let idleInput: Duration = .milliseconds(750)
    /// A pane resize or focus change settles this long before the parked spare follows
    /// (a live window resize lays the hidden page out once, at the end).
    static let fitSettle: Duration = .milliseconds(120)
    static let maximumOpenings = 64

    private unowned let services: AppServices
    private var slot = AgentPaneSpareSlot<AgentPaneView>()
    private let parking = PageOffscreenParking()
    /// The main window the spare parks in (the key one, or the last key one).
    private(set) weak var target: NSWindow?
    private let warmTimer = DemandTimer(owner: "NewTabSparePool.warm")
    private let fitTimer = DemandTimer(owner: "NewTabSparePool.fit")
    private var inputMonitor: Any?
    /// The app's memory pressure events; a warning or critical level drops the spare.
    private let memoryPressure: MemoryPressureEvents
    private var pressureObservation: MainActorHandlerRegistration<MemoryPressureLevel>?
    private var usedThisSession = false
    private var windowObservers: [any NSObjectProtocol] = []
    private(set) var openings: [Opening] = []
    /// Main-thread time of the last move of the parked spare to another window.
    private(set) var lastRetargetMilliseconds: Double?

    /// The native New Tab page's spare (`tabs.nativeNewTabPage`): one SwiftUI page, made and laid out
    /// in the parking view at the target pane's size at a quiet moment, so Cmd-T shows it with no
    /// build or layout (cmux19-perf: a cold native page showed on the 4th frame, 51 ms p50).
    private(set) var nativeSpare: NativeNewTabHostingView?
    /// Spares an open took, until the pane makes its tab's view (``claimNative(_:)``).
    private var nativeAdoptions: [String: NativeNewTabHostingView] = [:]
    private var wantsNative: Bool { services.settings?.snapshot.nativeNewTabPage == true }

    /// Makes the native spare now, parked in the target window (no-op when the setting is off, a
    /// spare is parked or no window is the target). The warm timer calls it; tests call it directly.
    func warmNative() {
        guard wantsNative, nativeSpare == nil, let content = target?.contentView else { return }
        park(in: content)
        let host = BenchSpans.measure("pool.makeNativeSpare") {
            NativeNewTabView.hosted(NativeNewTabModel(page: NewTabPage.sparePage(services), actions: NativeNewTabActions()))
        }
        host.frame = parking.bounds
        host.autoresizingMask = [.width, .height]
        parking.addSubview(host)
        host.layoutSubtreeIfNeeded()
        nativeSpare = host
    }

    /// The parked native spare for the new tab `key`, out of the parking view, or nil (the page is made
    /// cold). The pane's view for `key` claims it (``claimNative(_:)``); the next spare follows when input is quiet.
    func takeNative(for key: String) -> NativeNewTabHostingView? {
        guard let host = nativeSpare else { return nil }
        // Re-park the replacement in the next main-actor turn. Waiting for the idle-input
        // debounce here leaves the next Cmd-T/Cmd-N with no warm page at all.
        defer { scheduleWarmImmediately() }
        nativeSpare = nil
        host.removeFromSuperview()
        // One opening at a time: a spare an earlier open took but no pane claimed (its tab closed first) goes.
        nativeAdoptions = [key: host]
        return host
    }

    /// Tab `key` shows a spare already made (its showing builds nothing: the presentation budget allows it now).
    func hasNativeAdoption(_ key: String) -> Bool { nativeAdoptions[key] != nil }

    /// The spare taken for tab `key`, once.
    func claimNative(_ key: String) -> NativeNewTabHostingView? { nativeAdoptions.removeValue(forKey: key) }

    /// In place of ``AgentTabs/makeSpare(_:)`` (WebKit's first load, on the main thread): tests stall it.
    var makeSpare: ((AgentPaneNewTab) -> AgentPaneView?)?
    init(services: AppServices, memoryPressure: MemoryPressureEvents) {
        self.services = services
        self.memoryPressure = memoryPressure
    }


    /// At launch: probes WebKit's setup off the main thread, no spare yet (a first load held launch >10 s, cua-2).
    func prewarm() {
        if services.agentTabs.canHostChat { webKit.probe { [weak self] in self?.scheduleWarm() } }
    }

    /// WebKit's setup on this host; a slow one gets no spare this run.
    let webKit = WebKitSetupGate()
    /// At launch: follow the key main window; park in the first visible one.
    func start() {
        services.agentTabs.recycle = { [weak self] view in self?.recycle(view) ?? false }
        // The first page of a new workspace (Cmd-N, an empty window's New Tab page) adopts the
        // spare too, so a cold Cmd-N shows a page that already loaded (cx-ec99).
        services.agentTabs.takeSpare = { [weak self] in
            guard let self, let window = self.services.keyWindowSource().flatMap(self.mainWindow) ?? self.target else { return nil }
            let start = ContinuousClock.now
            let spare = self.take(for: window, size: nil)
            self.record(.init(spare: spare != nil, crossWindow: spare?.crossWindow == true, milliseconds: Self.milliseconds(since: start)))
            return spare?.view
        }
        // A tab opening an existing chat of this Mac adopts it only once its client is connected
        // (AgentPaneSpareAdoption): it switches to the chat in place. One still connecting stays here,
        // and the tab opens cold as before: adopted, it would hold the open behind its chat list.
        services.agentTabs.takeConnectedSpare = { [weak self] in
            guard let self else { return nil }
            guard let spare = slot.peek,
                  let window = self.services.keyWindowSource().flatMap(self.mainWindow) ?? self.target else {
                AgentPaneSpareOutcome.empty.trace()
                return nil
            }
            guard spare.model.servesExistingChat else {
                AgentPaneSpareOutcome.unready.trace()
                return nil
            }
            return take(for: window, size: nil, refill: .whenQuiet)?.view
        }
        observeWindows()
        if let window = services.keyWindowSource().flatMap(mainWindow) ?? services.windows.controllers.compactMap(\.window).first(where: \.isVisible) {
            retarget(window)
        }
    }

    private func mainWindow(_ window: NSWindow) -> NSWindow? {
        services.windows.controllers.contains { $0.window === window } ? window : nil
    }

    /// The parked spare follows the key main window; a closing target hands
    /// it to another main window (window notifications, no scan).
    private func observeWindows() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self, let window = window.flatMap(self.mainWindow) else { return }
                self.retarget(window)
            }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self, let window, window === self.target else { return }
                let next = self.services.windows.controllers.compactMap(\.window).first { $0 !== window && $0.isVisible }
                if let next { self.retarget(next) } else { self.dropAll() }
            }
        })
    }

    /// Parks the spare in `window`: moves the parked page there (no reload),
    /// or starts one at the next quiet moment when there is none.
    func retarget(_ window: NSWindow) {
        guard window !== target else { return }
        target = window
        guard let content = window.contentView else { return }
        let start = ContinuousClock.now
        park(in: content)
        if !slot.shouldWarm { lastRetargetMilliseconds = Self.milliseconds(since: start) }
        scheduleWarm()
    }

    /// Parks the parking view in `content`, at the target pane's size. It does not follow the
    /// window's size: ``fitParked()`` follows the pane's.
    private func park(in content: NSView) {
        if parking.superview !== content {
            parking.autoresizingMask = []
            content.addSubview(parking, positioned: .below, relativeTo: nil)
        }
        fitParked()
    }

    /// The size of the pane content a Cmd-T in the target window fills: its focused pane's.
    private var targetPaneSize: NSSize? {
        guard let pane = targetPane else { return nil }
        let size = Self.newTabContentSize(in: pane)
        return size.width > 0 && size.height > 0 ? size : nil
    }
    private var targetPane: PaneController? { services.windows.controllers.first { $0.window === target }?.content?.focusedPane }
    /// The parked spare draws the context a Cmd-T in the target window gives (NewTabPage.open), so the adoption changes
    /// no screen (SHORTCUT FRAMES F2); `preparedFor` is the focused pane and tab it was made for.
    private var preparedPage: AgentPaneNewTab {
        guard let pane = targetPane, pane.daemon.isLocal else { return NewTabPage.sparePage(services) }
        return NewTabPage.page(services, selected: pane.selectedTab, window: pane.view.window, pane: pane, paletteActions: false)
    }
    private var preparedFor: [AnyHashable]?
    private var targetIdentity: [AnyHashable]? { targetPane.map { [ObjectIdentifier($0), $0.selectedTab?.id] } }
    private func prepare(_ view: AgentPaneView) {
        preparedFor = targetIdentity
        BenchSpans.measure("pool.prepare") { view.prepareNewTab(preparedPage) }
    }

    /// The size a Cmd-T tab in `pane` shows at: the pane less its tab bar, also where a browser's
    /// header band holds the bar now (the band goes with the browser).
    static func newTabContentSize(in pane: PaneController) -> NSSize {
        let scale = pane.view.window?.backingScaleFactor ?? 2
        let strip = pane.hidesTabBar || pane.isAppPane ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        return NSSize(width: pane.view.bounds.width, height: max(0, pane.view.bounds.height - strip))
    }

    /// Sizes the parking view and the spare in it to the target pane now, laid out, so the
    /// page commits at that size long before an adoption.
    private func fitParked() {
        guard let content = parking.superview else { return }
        let size = targetPaneSize ?? content.bounds.size
        let resized = parking.frame != PageOffscreenParking.frame(in: content.bounds, size: size)
        if resized { BenchSpans.measure("pool.fit") { parking.fit(to: size) } }
        let shown = slot.peek?.model.newTab
        if let view = slot.peek, view.superview === parking { prepare(view) }
        if resized || slot.peek?.model.newTab != shown { snapshotParked() }
    }

    /// A pane of `window` changed size, or its focus or selected tab moved: the parked spare follows
    /// the target pane once that settles (``fitSettle``). Nothing is scheduled while it fits.
    func paneLayoutDidChange(in window: NSWindow?) {
        guard let window, window === target, let content = parking.superview else { return }
        let size = targetPaneSize ?? content.bounds.size
        guard targetIdentity != preparedFor || parking.frame != PageOffscreenParking.frame(in: content.bounds, size: size) else { return }
        fitTimer.schedule(after: Self.fitSettle) { @MainActor [weak self] in self?.fitParked() }
    }

    /// The spare for a new tab page in `window`, or nil (the page loads cold).
    /// A spare parked in another window is adopted all the same (a reparent).
    /// The caller adopts it at once; the next spare follows as `refill` says.
    /// `refit` is true when the spare waited at another size than `size`, the one it shows at
    /// (nil: not known yet, Cmd-N): its adoption resizes it.
    func take(for window: NSWindow?, size: NSSize?, refill: AgentPaneSpareRefill = .now) -> (view: AgentPaneView, crossWindow: Bool, refit: Bool)? {
        usedThisSession = true
        observeWindows()
        if target == nil, let window { retarget(window) }
        guard let view = slot.take() else { return nil }
        // Hand the parked page out now, then start making its replacement without waiting for
        // the user's input to go quiet. The replacement is background work on the next turn;
        // a later New Tab click therefore does not fall back to a cold mount.
        defer { if refill == .now { scheduleWarmImmediately() } else { scheduleWarm() } }
        snapshotGeneration &+= 1
        view.redraw.newTabFrameCaptureChanged = nil
        view.isHidden = false
        // The launch's page took the prewarmed spare: the next one starts once that page painted,
        // not after quiet input, so a Cmd-N right after launch finds a page loading (cx-ec99).
        if !warmedOnce {
            warmedOnce = true
            view.model.whenPainted { Task { @MainActor [weak self] in self?.warmNow() } }
        }
        opening = (ObjectIdentifier(view), size)
        return (view, window !== target, size.map { view.frame.size != $0 } ?? false)
    }

    /// The spare taken last and the size its opening shows it at, when known.
    private var opening: (view: ObjectIdentifier, size: NSSize?)?
    /// Only the latest parked capture may put its page to sleep.
    private var snapshotGeneration: UInt64 = 0
    func openingSize(of view: AgentPaneView) -> NSSize? { opening.flatMap { $0.view == ObjectIdentifier(view) ? $0.size : nil } }

    /// The parked spare's own frame at its size: its adoption's cover (`AgentTabContent.coverMove`),
    /// not the last New Tab page shown, drawn at another size or moment (4 px off, 2026-10-15).
    private func snapshotParked() {
        guard let view = slot.peek, view.superview === parking else { return }
        view.redraw.newTabFrameCaptureChanged = { [weak self, weak view] capturing in
            guard let self, let view, slot.peek === view, view.superview === parking else { return }
            if capturing {
                // A late chats.page answer invalidates the first cover. Keep the renderer awake
                // through the replacement capture, and invalidate any older sleep completion.
                snapshotGeneration &+= 1
                view.isHidden = false
            } else {
                snapshotParked()
            }
        }
        guard !view.redraw.givesNewTabFrame else { return }
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        // Rendering is needed only until this capture finishes, including after a parked resize.
        view.isHidden = false
        let appearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        view.model.whenPainted { [weak self, weak view] in
            guard let self, let view, snapshotGeneration == generation, slot.peek === view,
                  view.superview === parking else { return }
            view.redraw.rememberFrame(of: view, appearance: appearance) { [weak self, weak view] in
                guard let self, let view, snapshotGeneration == generation, slot.peek === view,
                      view.superview === parking else { return }
                // The offscreen parking view already keeps the page out of sight while allowing
                // WebKit/Chromium to render. Keep the view visible so its renderer stays warm;
                // hiding it here suspends the renderer and makes the next handout cold again.
            }
        }
    }

    /// A closed new tab page that never became a chat or a terminal: reset to
    /// the spare context (the page remounts its screen) and parked as the
    /// spare, so the close does no teardown and the pool builds nothing (R81).
    /// False when the slot is full or no page is likely.
    /// Why the last closed new tab page was not recycled (`debug.new_tab`).
    private(set) var lastRecycleRefusal: String?

    func recycle(_ view: AgentPaneView) -> Bool {
        lastRecycleRefusal = view.model.neverPooled ? "another machine's page" : !slot.shouldWarm ? "slot full" : view.model.newTab == nil ? "became a chat"
            : view.model.userTouched ? "touched by \(view.model.touchedBy ?? "?")" : target == nil ? "no target window" : nil
        guard lastRecycleRefusal == nil else { return false }
        BenchSpans.measure("pool.recycle") {
            view.adoptNewTab(NewTabPage.sparePage(services))
            // Out of the view tree now (as cheap as a close); back into the window at the next
            // quiet moment: putting a WKWebView back into a window costs a 15-20 ms commit, which
            // in the close frame dropped a frame on every Cmd-W (R81 bench).
            view.removeFromSuperview()
            slot.parked(view)
        }
        scheduleWarm()
        return true
    }

    func record(_ opening: Opening) {
        openings.append(opening)
        if openings.count > Self.maximumOpenings { openings.removeFirst(openings.count - Self.maximumOpenings) }
    }

    /// The parked spare, for `debug.new_tab`: its window number and page view.
    var spare: (window: Int, view: AgentPaneView)? {
        guard let view = parking.subviews.first as? AgentPaneView, let window = target else { return nil }
        return (window.windowNumber, view)
    }

    /// Drops the spare (memory pressure, the last window closing).
    func dropAll() {
        nativeSpare?.removeFromSuperview()
        nativeSpare = nil
        guard let view = slot.drop() else { return }
        view.redraw.newTabFrameCaptureChanged = nil
        view.removeFromSuperview()
        view.close()
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    // MARK: Warming

    /// Arms the quiet-input deadline; each key or click pushes it back.
    private func scheduleWarm() {
        let web = services.agentTabs.canHostChat && (slot.shouldWarm || unparked != nil)
        guard target != nil, web || (wantsNative && nativeSpare == nil) else { return }
        watchMemoryPressure()
        if inputMonitor == nil {
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) {
                [weak self] event in
                self?.armWarmTimer()
                return event
            }
        }
        armWarmTimer()
    }

    /// Replaces a handed-out spare on the next main-actor turn. A handout is a background
    /// rewarm boundary, not an idle-input boundary: the pool must have another fully rendered
    /// composer ready for the next New Tab or new workspace.
    private func scheduleWarmImmediately() {
        let web = services.agentTabs.canHostChat && (slot.shouldWarm || unparked != nil)
        guard target != nil, web || (wantsNative && nativeSpare == nil) else { return }
        watchMemoryPressure()
        warmTimer.schedule(after: .zero) { @MainActor [weak self] in self?.warmNow() }
    }

    /// Whether this run has warmed a spare yet: the first one starts at once, before the person
    /// types (a cold launch's first Cmd-N then finds a page that is loading or loaded, cx-ec99).
    private var warmedOnce = false

    private func armWarmTimer() {
        // Only the launch warm comes early, after the first frame: a `take()` that found nothing
        // (it set `usedThisSession`) must not make a web view in the person's keystroke.
        let launch = !warmedOnce && !usedThisSession
        warmedOnce = warmedOnce || launch
        warmTimer.schedule(after: launch ? .milliseconds(250) : Self.idleInput) { @MainActor [weak self] in self?.warmNow() }
    }

    /// A recycled spare not yet back in the window.
    private var unparked: AgentPaneView? {
        guard let view = slot.peek, view.superview == nil else { return nil }
        return view
    }

    private func warmNow() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        warmNative()
        guard services.agentTabs.canHostChat else { return }
        if let view = unparked, let content = target?.contentView {
            park(in: content)
            view.frame = parking.bounds
            view.autoresizingMask = [.width, .height]
            BenchSpans.measure("pool.park") { parking.addSubview(view) }
            prepare(view)
            return snapshotParked()
        }
        guard webKit.state == .ready else { return webKit.probe { [weak self] in self?.scheduleWarm() } }
        guard slot.shouldWarm, let content = target?.contentView else { return }
        let start = ContinuousClock.now, page = preparedPage, identity = targetIdentity
        let made = BenchSpans.measure("pool.makeSpare") { makeSpare?(page) ?? services.agentTabs.makeSpare(page) }
        if ContinuousClock.now - start > .seconds(1) { webKit.markSlow() } // it held the main thread
        guard let view = made else { return }
        park(in: content)
        view.frame = parking.bounds
        view.autoresizingMask = [.width, .height]
        parking.addSubview(view)
        slot.parked(view)
        preparedFor = identity
        snapshotParked()
    }

    private func watchMemoryPressure() {
        guard pressureObservation == nil else { return }
        pressureObservation = memoryPressure.observe { [weak self] level in
            if level != .normal { self?.dropAll() }
        }
    }
}
