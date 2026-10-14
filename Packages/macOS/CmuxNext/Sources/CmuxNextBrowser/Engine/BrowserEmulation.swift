public import Foundation

/// A device emulation as the daemon resolved it for one tab (the tab's
/// `extra.emulation`, browser-devices-v1, cx-ocbf3). The daemon owns the
/// device list, the choice and every value; an engine only applies them.
public nonisolated struct BrowserEmulation: Sendable, Hashable {
    /// The device's CSS viewport size.
    public var width: Int
    public var height: Int
    public var deviceScaleFactor: Double
    /// Empty keeps the engine's own user agent.
    public var userAgent: String
    /// The DevTools calls Chrome's device mode sends, as the daemon wrote
    /// them: JSON of `[{method, params}]`. A Chromium engine sends them as
    /// given, only lowering `Emulation.setDeviceMetricsOverride`'s `scale` so
    /// a device bigger than the pane fits (as Chrome does).
    public var chromiumCallsJSON: String

    public init(width: Int, height: Int, deviceScaleFactor: Double, userAgent: String, chromiumCallsJSON: String) {
        self.width = width
        self.height = height
        self.deviceScaleFactor = deviceScaleFactor
        self.userAgent = userAgent
        self.chromiumCallsJSON = chromiumCallsJSON
    }

    /// The scale that fits the device in `available` points (at most 1), in
    /// whole percent rounded down, as Chrome's `calculateFitScale`.
    public func fitScale(in available: CGSize) -> CGFloat {
        guard available.width > 0, available.height > 0, width > 0, height > 0 else { return 1 }
        let scale = min(1, available.width / CGFloat(width), available.height / CGFloat(height))
        return max(0.01, (scale * 100).rounded(.down) / 100)
    }
}

/// A tab whose engine applies the daemon's emulation record.
@MainActor
public protocol BrowserEmulating: AnyObject {
    /// The record the tab applies, nil for none.
    var deviceEmulation: BrowserEmulation? { get }
    /// Applies `emulation` (nil ends it) and keeps it across navigations.
    func applyEmulation(_ emulation: BrowserEmulation?)
}
