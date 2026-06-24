public import SwiftUI

/// Drives a panel's focus-flash overlay: when ``token`` changes it pulses an
/// opacity value through ``FocusFlashPattern/standard`` and hands each frame to
/// a caller-supplied ``overlay`` builder (the app's accent ring view).
///
/// The modifier owns only the transient animation state (the current opacity and
/// a monotonic generation counter); the token source of truth stays on the
/// caller's model. Re-triggering cancels the in-flight pulse, and the pulse also
/// cancels when the host view leaves the hierarchy, so a stale segment can never
/// write opacity after a newer pulse started.
///
/// ``FocusFlashSegment/delay`` is an absolute offset from the pulse start, so the
/// driver sleeps each segment's inter-segment gap (its delay minus the previous
/// segment's delay) on a ``ContinuousClock`` (cancellation-aware, unlike
/// `DispatchQueue.asyncAfter`) and then applies the segment's curve via
/// ``SwiftUI/withAnimation(_:_:)``. Summing the gaps reproduces the original
/// timeline, where every segment was scheduled at once at its absolute deadline.
/// The generation guard makes every post-sleep write an idempotent no-op once a
/// newer pulse has begun, so no `Task.isCancelled` check is needed.
public struct FocusFlashViewModifier<FlashOverlay: View>: ViewModifier {
    private let token: Int
    private let pattern: FocusFlashPattern
    private let overlay: (Double) -> FlashOverlay

    @State private var opacity = 0.0
    @State private var generation = 0
    @State private var flashTask: Task<Void, Never>?

    /// - Parameters:
    ///   - token: A value the caller bumps to start a new flash pulse.
    ///   - pattern: The keyframe pattern to pulse through. Defaults to
    ///     ``FocusFlashPattern/standard``.
    ///   - overlay: Builds the overlay rendered above the content for the current
    ///     pulse opacity (typically the app's accent ring).
    public init(
        token: Int,
        pattern: FocusFlashPattern = .standard,
        @ViewBuilder overlay: @escaping (Double) -> FlashOverlay
    ) {
        self.token = token
        self.pattern = pattern
        self.overlay = overlay
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                overlay(opacity)
            }
            .onChange(of: token) {
                trigger()
            }
            .onDisappear {
                flashTask?.cancel()
                flashTask = nil
            }
    }

    private func trigger() {
        generation &+= 1
        let pulse = generation
        opacity = pattern.values.first ?? 0

        flashTask?.cancel()
        flashTask = Task { @MainActor in
            // `FocusFlashSegment.delay` is an absolute offset from pulse start,
            // and the original driver scheduled every segment at once with
            // `asyncAfter(deadline: .now() + delay)`, so all fire on one
            // timeline. Sleeping sequentially must therefore wait only the
            // inter-segment gap (this segment's absolute delay minus the
            // previous one), not the absolute delay each iteration, or the
            // pulse stretches and its keyframe spacing distorts.
            var previousDelay: TimeInterval = 0
            for segment in pattern.segments {
                let gap = segment.delay - previousDelay
                previousDelay = segment.delay
                if gap > 0 {
                    do {
                        try await ContinuousClock().sleep(for: .seconds(gap))
                    } catch {
                        return
                    }
                }
                guard generation == pulse else { return }
                withAnimation(Self.animation(for: segment.curve, duration: segment.duration)) {
                    opacity = segment.targetOpacity
                }
            }
        }
    }

    private static func animation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

extension View {
    /// Drives a focus-flash overlay from ``token`` using
    /// ``FocusFlashViewModifier``. The token source of truth stays on the
    /// caller's model; bump it to start a pulse.
    public func focusFlash<FlashOverlay: View>(
        token: Int,
        pattern: FocusFlashPattern = .standard,
        @ViewBuilder overlay: @escaping (Double) -> FlashOverlay
    ) -> some View {
        modifier(FocusFlashViewModifier(token: token, pattern: pattern, overlay: overlay))
    }
}
