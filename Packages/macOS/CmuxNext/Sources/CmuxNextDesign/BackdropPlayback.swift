public import Foundation
import IOKit.ps

/// When a video background plays (`appearance.backgroundVideo`, backgrounds plan phase 5).
public nonisolated enum BackdropVideoMode: String, CaseIterable, Sendable {
    /// Plays while someone can see it and the Mac can afford it.
    case play
    /// Plays only while cmux is the active app.
    case whenActive
    /// Never plays: its first frame stays, and its decoder is given back.
    case still
}

/// What a video background does on battery (`appearance.backgroundVideoOnBattery`). Low Power
/// Mode pauses it either way.
public nonisolated enum BackdropBatteryMode: String, CaseIterable, Sendable {
    case play
    case pause
}

/// The background settings the window backdrop and its video read.
public nonisolated struct BackdropPlaybackSettings: Hashable, Sendable {
    public var video: BackdropVideoMode = .play
    public var onBattery: BackdropBatteryMode = .play
    /// Keep a painting's subject clear of the sidebar and agent chat (`appearance.backgroundAvoidPanes`).
    public var avoidsPanes = true

    public init(video: BackdropVideoMode = .play, onBattery: BackdropBatteryMode = .play, avoidsPanes: Bool = true) {
        self.video = video
        self.onBattery = onBattery
        self.avoidsPanes = avoidsPanes
    }
}

/// Whether this Mac runs on battery, and a notification when that changes (IOKit's power source
/// list, watched from the main run loop once something asks).
@MainActor
public final class BackdropPower {
    public static let shared = BackdropPower()
    /// Posted (object: the monitor) when the Mac moves to or from battery.
    public static let didChange = Notification.Name("BackdropPower.didChange")

    public private(set) var onBattery = BackdropPower.readOnBattery()
    private var source: CFRunLoopSource?

    private init() {}

    /// Starts watching the power source (idempotent).
    public func watch() {
        guard source == nil else { return }
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            // main-proof: the source is added to the main run loop below
            MainActor.assumeIsolated { BackdropPower.shared.refresh() }
        }, nil)?.takeRetainedValue()
        guard let source else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func refresh() {
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              // A Get-rule function: the string belongs to `info`, not to us.
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }
}
