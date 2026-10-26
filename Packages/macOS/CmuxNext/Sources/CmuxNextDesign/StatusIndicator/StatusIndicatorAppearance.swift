public import AppKit
import CmuxNextCompat
import Observation
import CmuxNextWakeups
public import CmuxNextDesignTokens

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
@MainActor
public final class StatusIndicatorAppearance {
    public static let shared = StatusIndicatorAppearance()

    public private(set) var config: StatusIndicatorConfig
    /// Indicators a resync reached and checked again (`debug.layout_counters` `indicator_resyncs`):
    /// an app activation should touch the indicators on screen only, never every row and tab.
    public static var resyncs: UInt64 = 0
    private let clients = NSHashTable<AnyObject>.weakObjects()
    private var observation: Task<Void, Never>?
    private var reduceMotionObserver: MainActorObservation?
    private var reduceMotionOverrideObserver: (any NSObjectProtocol)?
    private var resyncObservers: [MainActorObservation] = []

    /// - Parameters:
    ///   - appCenter: Where the app and window notices arrive (tests post to their own).
    ///   - workspaceCenter: Where the wake notices arrive.
    init(appCenter: NotificationCenter = .default, workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        config = StatusIndicatorConfig.current
        startObserving()
        // Reduce Motion is not observable through Observation.
        let center = NSWorkspace.shared.notificationCenter
        reduceMotionObserver = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: center) { [weak self] in
            self?.apply(StatusIndicatorConfig.current)
        }
        // The override (tests) is a plain static: re-read synchronously when it
        // changes, or an appearance created before the override keeps the
        // system setting's loops (a runner with Reduce Motion on shows no spinner).
        reduceMotionOverrideObserver = NotificationCenter.default.addObserver(
            forName: Motion.reduceMotionDidChange, object: nil, queue: nil) { [weak self] _ in
            MainDelivery().run { self?.apply(StatusIndicatorConfig.current) }
        }
        observeResyncMoments(app: appCenter, workspace: workspaceCenter)
    }

    /// Indicators pause while their window is hidden and resume on its occlusion notice; a notice
    /// that never comes (a row out of the list when it was posted, a wake that posts none) used to
    /// leave every row's spinner still until its state changed (Leo 2026-10-20). Whenever the app
    /// comes back, every indicator checks itself again.
    private func observeResyncMoments(app: NotificationCenter, workspace: NotificationCenter) {
        let moments: [(NotificationCenter, Notification.Name)] = [
            (app, NSApplication.didBecomeActiveNotification), (app, NSApplication.didUnhideNotification),
            (app, NSWindow.didBecomeMainNotification), (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification), (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        resyncObservers = moments.map { center, name in
            MainActorObservation(name, center: center) { [weak self] in self?.resync() }
        }
    }

    /// Tells every client to check its indicator again (`statusIndicatorResync`).
    public func resync() {
        for case let client as any StatusIndicatorConfigClient in clients.allObjects {
            client.statusIndicatorResync()
        }
    }

    /// Adds `client`; it is told about every later change (weakly held).
    public func register(_ client: any StatusIndicatorConfigClient) {
        clients.add(client)
    }

    /// Settings previews and commits publish to mounted indicators in the same main-actor turn.
    /// The observation task still follows Debug tunables and motion changes made elsewhere.
    public func refresh() {
        apply(StatusIndicatorConfig.current)
    }

    private func startObserving() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            for await next in ObservationStream({ StatusIndicatorConfig.current }) {
                guard let self else { return }
                self.apply(next)
            }
        }
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
