public import AppKit

/// The refresh range of a display (`NSScreen`'s minimum and maximum refresh intervals).
public struct PresentationDisplay: Sendable, Hashable {
    /// The shortest refresh interval (the fastest rate), in seconds.
    public let minimumRefreshInterval: Double
    /// The longest refresh interval (the slowest rate), in seconds.
    public let maximumRefreshInterval: Double

    public init(minimumRefreshInterval: Double, maximumRefreshInterval: Double) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.maximumRefreshInterval = maximumRefreshInterval
    }

    /// The range of `screen`.
    @MainActor
    public init(screen: NSScreen) {
        self.init(minimumRefreshInterval: screen.minimumRefreshInterval, maximumRefreshInterval: screen.maximumRefreshInterval)
    }

    /// The range of the screen of `scheduler`'s window, or the main screen; nil with no screen.
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
