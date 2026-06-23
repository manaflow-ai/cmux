public import Foundation
public import CmuxTerminalCore

/// The keyframe pattern of a panel focus-flash: a 0→1→0→1→0 opacity pulse over
/// ``duration`` seconds, alternating ease-out/ease-in between stops.
///
/// Faithful lift of the app-target focus-flash source of truth. It lowers into
/// the AppKit-free ``TerminalPaneFlashAnimationSpec`` the overlay container
/// animates from, and also exposes the resolved ``segments`` and a sampled
/// ``opacity(at:)`` for callers driving the flash manually.
///
/// Modeled as a static-only namespace to preserve the existing
/// `FocusFlashPattern.*` call shape byte-for-byte; promoting it to a value type
/// is a deferred redesign.
public enum FocusFlashPattern {
    public static let values: [Double] = [0, 1, 0, 1, 0]
    public static let keyTimes: [Double] = [0, 0.25, 0.5, 0.75, 1]
    public static let duration: TimeInterval = 0.9
    public static let curves: [FocusFlashCurve] = [.easeOut, .easeIn, .easeOut, .easeIn]

    /// This pattern lowered into the AppKit-free `Sendable` spec the terminal
    /// overlay container animates from.
    public static var paneAnimationSpec: TerminalPaneFlashAnimationSpec {
        TerminalPaneFlashAnimationSpec(
            values: values,
            keyTimes: keyTimes,
            duration: duration,
            curves: curves.map { curve in
                switch curve {
                case .easeIn: return .easeIn
                case .easeOut: return .easeOut
                }
            }
        )
    }
    public static let ringInset: Double = Double(PanelOverlayRingMetrics.inset)
    public static let ringCornerRadius: Double = Double(PanelOverlayRingMetrics.cornerRadius)

    public static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }

    public static func opacity(at elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed <= duration else { return 0 }

        for index in 0..<segments.count {
            let startTime = keyTimes[index] * duration
            let endTime = keyTimes[index + 1] * duration
            if elapsed > endTime {
                continue
            }

            let segmentDuration = max(endTime - startTime, 0.0001)
            let rawProgress = max(0, min(1, (elapsed - startTime) / segmentDuration))
            let curvedProgress = Self.interpolatedProgress(rawProgress, curve: curves[index])
            let startOpacity = values[index]
            let endOpacity = values[index + 1]
            return startOpacity + ((endOpacity - startOpacity) * curvedProgress)
        }

        return values.last ?? 0
    }

    private static func interpolatedProgress(_ progress: Double, curve: FocusFlashCurve) -> Double {
        switch curve {
        case .easeIn:
            return progress * progress
        case .easeOut:
            let inverse = 1 - progress
            return 1 - (inverse * inverse)
        }
    }
}
