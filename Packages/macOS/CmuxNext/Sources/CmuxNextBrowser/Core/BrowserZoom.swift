import Foundation

/// Chromium's page zoom ladder and stepping rules, shared by every engine.
public nonisolated enum BrowserZoom {
    public static let levels: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0,
        1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0,
    ]

    public static var minimum: Double { levels[0] }
    public static var maximum: Double { levels[levels.count - 1] }

    public static func clamp(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, minimum), maximum)
    }

    /// The next ladder level above `zoom`. A value between levels snaps to the
    /// next level up.
    public static func zoomIn(from zoom: Double) -> Double {
        levels.first { $0 > zoom + tolerance } ?? maximum
    }

    /// The next ladder level below `zoom`.
    public static func zoomOut(from zoom: Double) -> Double {
        levels.last { $0 < zoom - tolerance } ?? minimum
    }

    /// Percentage label value, e.g. 1.25 -> 125.
    public static func percent(_ zoom: Double) -> Int {
        Int((zoom * 100).rounded())
    }

    private static let tolerance = 0.001
}
