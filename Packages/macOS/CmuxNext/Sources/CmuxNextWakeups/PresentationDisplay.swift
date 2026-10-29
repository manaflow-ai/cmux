public import AppKit

/// A display and its refresh range (`NSScreen`'s minimum and maximum refresh intervals). Two values
/// are equal only for the same display with the same range: a vsync phase belongs to one of them.
public struct PresentationDisplay: Sendable, Hashable {
    /// The display (`CGDirectDisplayID`, as DisplayClock keys its links); nil when unknown.
    public let displayID: CGDirectDisplayID?
    /// The shortest refresh interval (the fastest rate), in seconds.
    public let minimumRefreshInterval: Double
    /// The longest refresh interval (the slowest rate), in seconds.
    public let maximumRefreshInterval: Double

    /// A display's refresh range; nil `displayID` for a display that is not known.
    public init(displayID: CGDirectDisplayID? = nil, minimumRefreshInterval: Double, maximumRefreshInterval: Double) {
        self.displayID = displayID
        self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshInterval = maximumRefreshInterval
    }

    /// The display of `screen`.
    @MainActor
    public init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(displayID: number?.uint32Value, minimumRefreshInterval: screen.minimumRefreshInterval,
                  maximumRefreshInterval: screen.maximumRefreshInterval)
    }

    /// The display of `scheduler`'s window, or the main screen; nil with no screen.
    @MainActor
    public init?(screenOf scheduler: FrameScheduler) {
        guard let screen = scheduler.window?.screen ?? NSScreen.main else { return nil }
        self.init(screen: screen)
    }

    /// Variable refresh (ProMotion, adaptive sync): the intervals differ by more than float noise.
    public var isVariableRefresh: Bool {
        maximumRefreshInterval - minimumRefreshInterval > 0.000_1
    }
}
