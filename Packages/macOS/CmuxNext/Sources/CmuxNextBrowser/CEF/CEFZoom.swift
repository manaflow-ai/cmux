import Foundation

/// Chromium zoom levels are logarithmic: factor = 1.2 ^ level.
nonisolated enum CEFZoom {
    static func level(forFactor factor: Double) -> Double {
        guard factor > 0 else { return 0 }
        return log(factor) / log(1.2)
    }

    static func factor(forLevel level: Double) -> Double {
        pow(1.2, level)
    }
}
