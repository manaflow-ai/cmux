public import Foundation
public import CmuxTerminalCore

/// The keyframe pattern of a panel focus-flash: a 0→1→0→1→0 opacity pulse over
/// ``duration`` seconds, alternating ease-out/ease-in between stops.
///
/// A value type carrying its keyframes as stored data, with a shared
/// ``standard`` instance for the app's single flash pattern. It lowers into the
/// AppKit-free ``TerminalPaneFlashAnimationSpec`` the overlay container animates
/// from, and also exposes the resolved ``segments`` and a sampled
/// ``opacity(at:)`` for callers driving the flash manually.
public struct FocusFlashPattern: Equatable, Sendable {
    /// The opacity stops the pulse interpolates through.
    public let values: [Double]
    /// The normalized (0…1) time of each stop in ``values``.
    public let keyTimes: [Double]
    /// Total pulse duration in seconds.
    public let duration: TimeInterval
    /// The easing curve applied between each pair of adjacent stops.
    public let curves: [FocusFlashCurve]

    public init(
        values: [Double],
        keyTimes: [Double],
        duration: TimeInterval,
        curves: [FocusFlashCurve]
    ) {
        self.values = values
        self.keyTimes = keyTimes
        self.duration = duration
        self.curves = curves
    }

    /// The app's single focus-flash pattern: a 0→1→0→1→0 pulse over 0.9s.
    public static let standard = FocusFlashPattern(
        values: [0, 1, 0, 1, 0],
        keyTimes: [0, 0.25, 0.5, 0.75, 1],
        duration: 0.9,
        curves: [.easeOut, .easeIn, .easeOut, .easeIn]
    )

    /// The shared focus/attention overlay ring inset, surfaced here so flash
    /// callers reading the pattern do not also import ``PanelOverlayRingMetrics``.
    public static let ringInset: Double = Double(PanelOverlayRingMetrics.inset)
    /// The shared focus/attention overlay ring corner radius (see ``ringInset``).
    public static let ringCornerRadius: Double = Double(PanelOverlayRingMetrics.cornerRadius)

    /// This pattern lowered into the AppKit-free `Sendable` spec the terminal
    /// overlay container animates from.
    public var paneAnimationSpec: TerminalPaneFlashAnimationSpec {
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

    public var segments: [FocusFlashSegment] {
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

    public func opacity(at elapsed: TimeInterval) -> Double {
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
