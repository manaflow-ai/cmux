public import AppKit
import Observation
import CmuxNextWakeups

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

    public init(settings: StatusIndicatorSettings = StatusIndicatorSettings(), styleOverride: StatusIndicatorStyle? = nil,
                arcLength: Double = 0.72, trackOpacity: Double = 0.22, dotScale: Double = 0.5, pulseLow: Double = 0.35,
                nativeSteps: Int = 8, animatesLoops: Bool = true, spinnerPeriod: Double? = nil, pulsePeriod: Double? = nil,
                terminalFontFamily: String? = nil, iconSet: StatusIconSet = .current) {
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
    }

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
            animatesLoops: Motion.animatesLoops,
            spinnerPeriod: Motion.period(.spinner),
            pulsePeriod: Motion.period(.pulse),
            terminalFontFamily: DesignSettings.shared.terminalFontFamily,
            iconSet: StatusIconSet.tunable.value)
    }
}

/// A host that redraws its indicators when the config changes.
@MainActor
public protocol StatusIndicatorConfigClient: AnyObject {
    func statusIndicatorConfigDidChange(_ config: StatusIndicatorConfig)
}

/// The shared config and its change broadcast.
@MainActor
public final class StatusIndicatorAppearance {
    public static let shared = StatusIndicatorAppearance()

    public private(set) var config: StatusIndicatorConfig
    private let clients = NSHashTable<AnyObject>.weakObjects()
    private var observation: Task<Void, Never>?
    private var reduceMotionObserver: (any NSObjectProtocol)?
    private var reduceMotionOverrideObserver: (any NSObjectProtocol)?

    init() {
        config = StatusIndicatorConfig.current
        startObserving()
        // Reduce Motion is not observable through Observation.
        let center = NSWorkspace.shared.notificationCenter
        reduceMotionObserver = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(StatusIndicatorConfig.current) } // main-proof: observer on queue: .main
        }
        // The override (tests) is a plain static: re-read synchronously when it
        // changes, or an appearance created before the override keeps the
        // system setting's loops (a runner with Reduce Motion on shows no spinner).
        reduceMotionOverrideObserver = NotificationCenter.default.addObserver(
            forName: Motion.reduceMotionDidChange, object: nil, queue: nil) { [weak self] _ in
            MainDelivery().run { self?.apply(StatusIndicatorConfig.current) }
        }
    }

    /// Adds `client`; it is told about every later change (weakly held).
    public func register(_ client: any StatusIndicatorConfigClient) {
        clients.add(client)
    }

    private func startObserving() {
        guard observation == nil else { return }
        observation = Task { [weak self] in
            for await next in Observations({ StatusIndicatorConfig.current }) {
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
