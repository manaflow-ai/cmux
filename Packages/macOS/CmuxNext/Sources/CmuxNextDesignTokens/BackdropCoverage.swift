public import CoreGraphics
public import Foundation

/// How much of a window other windows hide (cx-14vdf follow-up, after idlesse's coverage rest).
/// `NSWindow.occlusionState` reports a window as visible while any pixel of it shows, so a cmux
/// window behind a browser with a sliver showing still decodes its video wallpaper. This samples
/// a 12 by 12 grid of points over the window against the windows above it, and the video rests
/// once nearly all of it is hidden:
///
/// - sampled every 3 s while the video is seen (a ``DemandTimer`` deadline, re-armed after each);
/// - rest at 95% covered, resume at 85% or less, each only after two samples in a row agree;
/// - only opaque app windows count (alpha 0.98 or more, at the normal window layer); the window's
///   own child windows (its clear overlay panel, a browser page's window), floating panels, the
///   menu bar, Dock, Control Center and other system chrome never do.
public nonisolated struct BackdropCoverage: Sendable, Equatable {
    /// One window above the one measured, in global screen coordinates.
    public struct Window: Sendable, Equatable {
        public var bounds: CGRect
        public var alpha: Double
        public var owner: String
        /// The window server's number for it, 0 when unknown.
        public var number: Int
        /// Its window layer; 0 is a normal app window.
        public var layer: Int

        public init(bounds: CGRect, alpha: Double = 1, owner: String = "", number: Int = 0, layer: Int = 0) {
            self.bounds = bounds
            self.alpha = alpha
            self.owner = owner
            self.number = number
            self.layer = layer
        }
    }

    public static let restThreshold = 0.95
    public static let resumeThreshold = 0.85
    public static let stableSamples = 2
    /// Seconds between samples while a video plays or rests on coverage.
    public static let interval: TimeInterval = 3
    package static let grid = 12
    package static let chrome: Set<String> = ["Dock", "Notification Center", "Screenshot", "Control Center", "SystemUIServer", "Window Server"]

    /// Whether the video rests now.
    public private(set) var resting = false
    private var streak = 0

    public init() {}

    /// The fraction of `frame` that `above` hides, 0...1, leaving out the windows numbered `own`.
    public static func covered(_ frame: CGRect, by above: [Window], ignoring own: Set<Int> = []) -> Double {
        let covers = above.filter {
            $0.layer == 0 && $0.alpha >= 0.98 && !chrome.contains($0.owner) && !own.contains($0.number) && $0.bounds.intersects(frame)
        }
        guard !frame.isEmpty, !covers.isEmpty else { return 0 }
        var hidden = 0
        for row in 0..<grid {
            for column in 0..<grid {
                let point = CGPoint(x: frame.minX + (Double(column) + 0.5) * frame.width / Double(grid),
                                    y: frame.minY + (Double(row) + 0.5) * frame.height / Double(grid))
                if covers.contains(where: { $0.bounds.contains(point) }) { hidden += 1 }
            }
        }
        return Double(hidden) / Double(grid * grid)
    }

    /// Takes one sample; returns whether the video rests after it.
    @discardableResult
    public mutating func sample(_ fraction: Double) -> Bool {
        let flips = resting ? fraction <= Self.resumeThreshold : fraction >= Self.restThreshold
        streak = flips ? streak + 1 : 0
        if streak >= Self.stableSamples {
            resting.toggle()
            streak = 0
        }
        return resting
    }

    /// Back to playing, as after the window was off screen and its coverage is stale.
    public mutating func reset() {
        resting = false
        streak = 0
    }

    /// The windows above window `number` on screen now, in global coordinates with the
    /// origin at the top left of the main display (CGWindowList's space).
    public static func windows(above number: Int) -> [Window] {
        guard number > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(number)) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) })
            else { return nil }
            return Window(bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                          owner: info[kCGWindowOwnerName as String] as? String ?? "",
                          number: info[kCGWindowNumber as String] as? Int ?? 0, layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
}
