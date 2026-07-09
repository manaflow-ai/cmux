public import AppKit

/// One recorded minimal-mode titlebar mouse-down, used to detect a manual
/// double-click formed by two consecutive single clicks.
///
/// A pure value type. The app target records the previous click on its event
/// monitor / window-decoration state and asks a freshly-built current click
/// whether it `formsDoubleClick(previous:)`.
public struct MinimalModeTitlebarClickRecord: Equatable {
    /// The `NSWindow.windowNumber` the click landed in.
    public let windowNumber: Int
    /// The event timestamp (`NSEvent.timestamp`) of the click.
    public let timestamp: TimeInterval
    /// The click location in window coordinates.
    public let locationInWindow: NSPoint

    /// Creates a click record.
    public init(
        windowNumber: Int,
        timestamp: TimeInterval,
        locationInWindow: NSPoint
    ) {
        self.windowNumber = windowNumber
        self.timestamp = timestamp
        self.locationInWindow = locationInWindow
    }

    /// Extra slack added to the system double-click interval so a
    /// synthetically-driven (UI test) second click still registers; zero in
    /// release builds to match the OS exactly.
    public static let syntheticDoubleClickTolerance: TimeInterval = {
        #if DEBUG
        0.15
        #else
        0
        #endif
    }()

    /// Reports whether this (current) click completes a double-click following
    /// `previous`.
    ///
    /// A `clickCount >= 2` is always a double-click. Otherwise the two clicks
    /// must hit the same window within `doubleClickInterval` (plus
    /// `doubleClickIntervalTolerance`) and within `maxDistance` points.
    public func formsDoubleClick(
        clickCount: Int,
        previous: MinimalModeTitlebarClickRecord?,
        doubleClickInterval: TimeInterval,
        doubleClickIntervalTolerance: TimeInterval = 0,
        maxDistance: CGFloat = 4
    ) -> Bool {
        if clickCount >= 2 {
            return true
        }
        let allowedInterval = max(0, doubleClickInterval) + max(0, doubleClickIntervalTolerance)
        guard let previous,
              previous.windowNumber == windowNumber,
              timestamp - previous.timestamp >= 0,
              timestamp - previous.timestamp <= allowedInterval else {
            return false
        }

        let dx = locationInWindow.x - previous.locationInWindow.x
        let dy = locationInWindow.y - previous.locationInWindow.y
        return hypot(dx, dy) <= maxDistance
    }
}
