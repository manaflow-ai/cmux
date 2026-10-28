public import AppKit
public import CmuxNextWakeups
public import CmuxNextDesignTokens
public import CmuxNextAppearance

/// Every input that shapes how indicators look, resolved once: the
/// `appearance.statusIndicator.*` settings plus the Debug Settings
/// tunables. One `Observations` sequence app-wide pushes changes to the
/// registered hosts, so a settings edit restyles every indicator live
/// without a task per row.
public nonisolated struct StatusIndicatorConfig: Hashable, Sendable {
    public var settings: StatusIndicatorSettings
    /// Debug Settings style override (prototype variants).
    public var styleOverride: StatusIndicatorStyle?
    public var arcLength: Double
    public var trackOpacity: Double
    public var dotScale: Double
    public var pulseLow: Double
    public var nativeSteps: Int
    /// Whether loops run (`ui.animationSpeed` and Reduce Motion), and their
    /// periods (Motion loop tokens and their tunables). Part of the config
    /// so a change restarts running animations with the new timing.
    public var animatesLoops: Bool
    public var spinnerPeriod: Double?
    public var pulsePeriod: Double?
    /// The terminal font the braille style draws in (`terminal.fontFamily`).
    public var terminalFontFamily: String?
    /// The status icon set (Debug Settings `status.iconSet`, cx-kxa2).
    public var iconSet: StatusIconSet
    /// System Reduce Motion (or its test override).
    public var reduceMotion: Bool
    /// The static look draws shapes instead of the Static set's glyphs
    /// (Debug Settings `status.static.shapes`).
    public var staticShapes: Bool
    /// How agent work shows (Debug Settings `status.working`).
    public var workingLook: StatusWorkingLook
    /// Lowest opacity of the working dot's breath.
    public var breathLow: Double { 0.3 }

    public init(settings: StatusIndicatorSettings = StatusIndicatorSettings(), styleOverride: StatusIndicatorStyle? = nil,
                arcLength: Double = 0.72, trackOpacity: Double = 0.22, dotScale: Double = 0.5, pulseLow: Double = 0.35,
                nativeSteps: Int = 8, animatesLoops: Bool = true, spinnerPeriod: Double? = nil, pulsePeriod: Double? = nil,
                terminalFontFamily: String? = nil, iconSet: StatusIconSet = .current, reduceMotion: Bool = false,
                staticShapes: Bool = false, workingLook: StatusWorkingLook = .spinner) {
        self.settings = settings
        self.styleOverride = styleOverride
        self.arcLength = arcLength
        self.trackOpacity = trackOpacity
        self.dotScale = dotScale
        self.pulseLow = pulseLow
        self.nativeSteps = nativeSteps
        self.animatesLoops = animatesLoops
        self.spinnerPeriod = spinnerPeriod
        self.pulsePeriod = pulsePeriod
        self.terminalFontFamily = terminalFontFamily
        self.iconSet = iconSet
        self.reduceMotion = reduceMotion
        self.staticShapes = staticShapes
        self.workingLook = workingLook
    }

    /// The static look (cx-sya4n): the setting says static, or Reduce Motion
    /// is on. Nothing animates and each state draws its own still shape in
    /// the same slot and size, whatever the icon set.
    public var isStatic: Bool { settings.animation == .static || reduceMotion }

    /// The style for a report that asked for `hint`: the Debug Settings
    /// override, else the hint, else the setting.
    public func style(hint: StatusIndicatorStyle?) -> StatusIndicatorStyle {
        styleOverride ?? hint ?? settings.style
    }

    /// The live values (reading them registers Observation dependencies).
    @MainActor public static var current: StatusIndicatorConfig {
        StatusIndicatorConfig(
            settings: DesignSettings.shared.statusIndicator,
            styleOverride: StatusIndicatorTunables.style.override,
            arcLength: StatusIndicatorTunables.arcLength.value,
            trackOpacity: StatusIndicatorTunables.trackOpacity.value,
            dotScale: StatusIndicatorTunables.dotScale.value,
            pulseLow: StatusIndicatorTunables.pulseLow.value,
            nativeSteps: Int(StatusIndicatorTunables.nativeSteps.value.rounded()),
            animatesLoops: Motion.indicators.animatesLoops,
            spinnerPeriod: Motion.indicators.period(.spinner),
            pulsePeriod: Motion.indicators.period(.pulse),
            terminalFontFamily: DesignSettings.shared.terminalFontFamily,
            iconSet: StatusIconSet.tunable.value,
            reduceMotion: Motion.reduceMotion,
            staticShapes: StatusIndicatorPlan.staticShapes.value,
            workingLook: StatusWorkingLook.tunable.value)
    }
}

/// A host that redraws its indicators when the config changes.
@MainActor
public protocol StatusIndicatorConfigClient: AnyObject {
    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig)
    /// Checks the indicator against what it should show now (its window's visibility, a loop it
    /// lacks) when the app comes back: to the front, unhidden, a window made main, or after sleep.
    func statusIndicatorResync()
}

public extension StatusIndicatorConfigClient {
    func statusIndicatorResync() {
        statusIndicatorConfigDidChange(StatusIndicatorAppearance.shared.config)
    }
}

/// The shared config and its change broadcast.
///
/// The composition root starts its follows once (``observe(on:appEvents:workspaceEvents:)``): the config is a
/// ``ServiceObservation`` in the `visible` class (it restyles the indicators on screen; a person's settings edit
/// flushes as `userBlocking`), and the resync moments are subscriptions on the app's one ``AppEvents`` per center,
/// as Chromium's app controller observes the NSApp notices once and fans them out
/// (`chrome/browser/app_controller_mac.mm`).
@MainActor
public final class StatusIndicatorAppearance {
    public static let shared = StatusIndicatorAppearance()

    public private(set) var config: StatusIndicatorConfig
    /// Indicators a resync reached and checked again (`debug.layout_counters` `indicator_resyncs`):
    /// an app activation should touch the indicators on screen only, never every row and tab.
    public static var resyncs: UInt64 = 0
    private let clients = NSHashTable<AnyObject>.weakObjects()
    private var observation: ServiceObservation<StatusIndicatorConfig>?
    private var reduceMotionWatch: AppearanceSignals.Subscription?
    private var resyncWatches: [EventSubscription] = []
    /// The windows whose visibility a resync reads again (``resync()``).
    private let windows: @MainActor () -> [NSWindow]

    /// - Parameter windows: The app's windows (tests pass their own).
    init(windows: @escaping @MainActor () -> [NSWindow] = { NSApplication.shared.windows }) {
        config = StatusIndicatorConfig.current
        self.windows = windows
        // Re-read synchronously when Reduce Motion flips (the system setting, the tests' pin or calm
        // mode), or an appearance created before a pin keeps the system setting's loops (a runner
        // with Reduce Motion on shows no spinner).
        reduceMotionWatch = DesignSettings.shared.signals.subscribe([.reduceMotion], owner: "StatusIndicatorAppearance") { [weak self] in
            self?.apply(StatusIndicatorConfig.current)
        }
    }

    /// Whether ``observe(on:appEvents:workspaceEvents:)`` ran (tests).
    var isObserving: Bool { observation != nil }

    /// Follows the config and the resync moments. The composition root calls it once, before the first window
    /// opens (`AppDelegate`, before `WindowManager.restoreWhenLoaded`); its first read applies any change made
    /// since ``shared`` was made. Later calls do nothing.
    ///
    /// - Parameters:
    ///   - mainWork: The app's one main-thread scheduler: a config change restyles in one posted task.
    ///   - appEvents: The app's fan-out of `NotificationCenter.default` notices.
    ///   - workspaceEvents: The app's fan-out of the workspace center's notices (the wakes).
    public func observe(on mainWork: MainWorkScheduler, appEvents: AppEvents, workspaceEvents: AppEvents) {
        guard observation == nil else { return }
        observation = ServiceObservation(.visible, owner: "StatusIndicatorAppearance", on: mainWork) {
            StatusIndicatorConfig.current
        } apply: { [weak self] next in
            self?.apply(next)
        }
        observeResyncMoments(app: appEvents, workspace: workspaceEvents)
    }

    /// Indicators pause while their window is hidden and resume on its occlusion notice; a notice
    /// that never comes (a row out of the list when it was posted, a wake that posts none) used to
    /// leave every row's spinner still until its state changed (Leo 2026-10-20). Whenever the app
    /// comes back, every indicator checks itself again. The subscriptions have no node: a resync
    /// reaches only the registered clients, and a hidden one defers its check to its own node.
    private func observeResyncMoments(app: AppEvents, workspace: AppEvents) {
        let owner = "StatusIndicatorAppearance.resync"
        let wakes = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification]
        resyncWatches = [
            app.subscribe(NSApplication.didBecomeActiveNotification, owner: owner) { [weak self] in self?.resync() },
            app.subscribe(NSApplication.didUnhideNotification, owner: owner) { [weak self] in self?.resync() },
            app.subscribe(NSWindow.didBecomeMainNotification, owner: owner) { [weak self] in self?.resync() },
        ] + wakes.map { name in
            workspace.subscribe(name, owner: owner) { [weak self] in self?.resync() }
        }
    }

    /// Reads each window's visibility again, then tells every client to check its indicator again
    /// (`statusIndicatorResync`). A window whose occlusion notice never came still has a stale node,
    /// and a hidden indicator waits on that node; an unchanged read flips nothing.
    public func resync() {
        for window in windows() { WindowVisibilitySource.installed(on: window)?.refresh() }
        for case let client as any StatusIndicatorConfigClient in clients.allObjects {
            client.statusIndicatorResync()
        }
    }

    /// Adds `client`; it is told about every later change (weakly held).
    public func register(_ client: any StatusIndicatorConfigClient) {
        clients.add(client)
    }

    /// Sets the config and tells every client (tests call it directly).
    func apply(_ next: StatusIndicatorConfig) {
        guard next != config else { return }
        config = next
        for case let client as any StatusIndicatorConfigClient in clients.allObjects {
            client.statusIndicatorConfigDidChange(next)
        }
    }
}
