#if os(iOS)
import SwiftUI
import UIKit

/// SPEC 2.7: every SwiftUI animation in the app goes through this gate. With Reduce Motion on, a change lands in
/// one frame instead of moving; `cmuxMobileAnimation(_:value:)` is the one place that swaps a move for the `snap`
/// crossfade instead. scripts/cmux-next/reduce-motion-audit.py counts any `withAnimation` or `.animation(` that does
/// not go through it.
extension Animation {
    /// This animation, or nil (no animation) when Reduce Motion is on.
    @MainActor public var unlessReduceMotion: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : self
    }
}

extension Optional where Wrapped == Animation {
    /// The wrapped animation, or nil when Reduce Motion is on.
    @MainActor public var unlessReduceMotion: Animation? {
        flatMap { $0.unlessReduceMotion }
    }
}
#endif
