import Foundation
import CmuxCanvas

/// User-configurable canvas-family layout settings.
///
/// Values persist through `UserDefaults` (mirrored into `~/.config/cmux/cmux.json`
/// by the settings catalog). Canvas operations share one canonical gap through
/// ``CanvasMetrics``; packed split modes share one divider thickness.
enum CanvasLayoutSettings {
    static let paneGapKey = "canvasPaneGap"
    static let snappingEnabledKey = "canvasSnappingEnabled"
    static let splitDividerThicknessKey = "canvasSplitDividerThickness"

    static let defaultPaneGap = CanvasMetrics.defaultGap
    static let defaultSnappingEnabled = true
    static let defaultSplitDividerThickness = 1

    static let paneGapRange: ClosedRange<Double> = 0...64
    static let splitDividerThicknessRange: ClosedRange<Int> = 1...12

    static func paneGap(defaults: UserDefaults = .standard) -> Double {
        // The settings catalog writes this key as Int (canvas.paneGap);
        // accept any numeric representation.
        guard let value = (defaults.object(forKey: paneGapKey) as? NSNumber)?.doubleValue else {
            return defaultPaneGap
        }
        return value.clamped(to: paneGapRange)
    }

    static func snappingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: snappingEnabledKey) as? Bool ?? defaultSnappingEnabled
    }

    static func splitDividerThickness(defaults: UserDefaults = .standard) -> CGFloat {
        guard let value = (defaults.object(forKey: splitDividerThicknessKey) as? NSNumber)?.intValue else {
            return CGFloat(defaultSplitDividerThickness)
        }
        return CGFloat(value.clamped(to: splitDividerThicknessRange))
    }

    /// The metrics every canvas operation should use right now.
    static func currentMetrics(defaults: UserDefaults = .standard) -> CanvasMetrics {
        CanvasMetrics(
            gap: paneGap(defaults: defaults),
            snapThreshold: snappingEnabled(defaults: defaults) ? CanvasMetrics.defaultSnapThreshold : 0,
            minPaneSize: CanvasMetrics.defaultMinPaneSize
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
