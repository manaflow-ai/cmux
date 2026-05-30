import CoreGraphics
import Foundation

/// The dimensionless constants of the Aurean Protocol: the golden ratio, the Fibonacci
/// spacing ladder, the φ type scale, motion timings, and the fixed chrome geometry.
///
/// These are pure declarations transcribed from the design's `tokens.css`. They carry no
/// behavior — only the numbers every surface is measured against. Multiply spacing by a
/// runtime `density` (0.75–1.4) at the call site; the ladder here is at density `1.0`.
public struct AureanMetrics: Sendable {
    /// The golden ratio, φ.
    public static let phi: CGFloat = 1.618033988749
    /// `1/φ` — the major share of a golden split (`0.618`).
    public static let phiInverse: CGFloat = 0.618033988749
    /// `1/φ²` (`0.382`) — the minor share of a golden split.
    public static let phiInverse2: CGFloat = 0.381966011250
    /// `1/φ³` (`0.236`).
    public static let phiInverse3: CGFloat = 0.236067977499
    /// `1/φ⁴` (`0.145`).
    public static let phiInverse4: CGFloat = 0.145898033750

    /// The Fibonacci spacing ladder in points, at density `1.0`.
    public struct Spacing: Sendable {
        public static let s1: CGFloat = 1
        public static let s2: CGFloat = 2
        public static let s3: CGFloat = 3
        public static let s5: CGFloat = 5
        public static let s8: CGFloat = 8
        public static let s13: CGFloat = 13
        public static let s21: CGFloat = 21
        public static let s34: CGFloat = 34
        public static let s55: CGFloat = 55
        public static let s89: CGFloat = 89
        public static let s144: CGFloat = 144
        public static let s233: CGFloat = 233
    }

    /// The φ-anchored type scale (anchor 16px, ratio φ) and its line metrics.
    public struct TypeScale: Sendable {
        /// The anchor size all others derive from.
        public static let anchor: CGFloat = 16
        /// `anchor / φ` ≈ 10 — uppercase technical labels.
        public static let micro: CGFloat = 10
        /// The body size (`anchor`).
        public static let base: CGFloat = 16
        /// `anchor · φ` ≈ 26.
        public static let h3: CGFloat = 26
        /// `h3 · φ` ≈ 42.
        public static let h2: CGFloat = 42
        /// `h2 · φ` ≈ 68.
        public static let h1: CGFloat = 68
        /// Base line-height multiple (φ).
        public static let lineHeight: CGFloat = 1.618
        /// Default letter tracking, in em.
        public static let tracking: CGFloat = 0.01
        /// Wide tracking for uppercase labels, in em.
        public static let trackingWide: CGFloat = 0.14
        /// The primary mono family, with fallbacks resolved by the platform.
        public static let monoFamily = "JetBrains Mono"
        /// Ordered fallbacks when the primary face is unavailable.
        public static let monoFallbacks = ["Fira Code", "Berkeley Mono", "SF Mono", "Menlo"]
    }

    /// Fibonacci-derived motion durations (seconds) and φ easing control points.
    public struct Motion: Sendable {
        /// Instant feedback (`160ms`).
        public static let feedback: Double = 0.160
        /// Micro interactions — selection, focus ring (`260ms`).
        public static let micro: Double = 0.260
        /// Panel and split transitions (`420ms`).
        public static let panel: Double = 0.420
        /// Context and workspace switches (`680ms`).
        public static let context: Double = 0.680
        /// The status-dot pulse cycle (`2618ms`, looped).
        public static let pulse: Double = 2.618
        /// Control points for the φ ease curve: `cubic-bezier(0.382, 0, 0.236, 1)`.
        public static let ease: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.382, 0, 0.236, 1)
        /// Control points for the φ ease-out curve: `cubic-bezier(0.145, 0.618, 0.236, 1)`.
        public static let easeOut: (CGFloat, CGFloat, CGFloat, CGFloat) = (0.145, 0.618, 0.236, 1)
    }

    /// Fixed chrome geometry in points.
    public struct Geometry: Sendable {
        /// Titlebar height.
        public static let titlebarHeight: CGFloat = 38
        /// Status bar height.
        public static let statusBarHeight: CGFloat = 27
        /// Pane header height.
        public static let paneHeaderHeight: CGFloat = 28
        /// Workspace rail width in the dense Cockpit direction.
        public static let railCockpitWidth: CGFloat = 208
        /// Workspace rail width in the calm Atelier direction (glyph-only).
        public static let railAtelierWidth: CGFloat = 64
        /// Right sidebar width in Cockpit.
        public static let rightSidebarCockpitWidth: CGFloat = 296
        /// Right sidebar width in Atelier.
        public static let rightSidebarAtelierWidth: CGFloat = 264
        /// Split gutter thickness.
        public static let gutter: CGFloat = 1
        /// Drag-grab tick length on the gutter.
        public static let gutterGrabTick: CGFloat = 34
        /// Inner focus-ring thickness (never a glow or shadow).
        public static let focusRing: CGFloat = 1
    }

    /// The golden pane split: there is no 50/50, and equalize (`⌥⌘=`) returns to this.
    public struct Split: Sendable {
        /// The major pane's fraction (`0.618`).
        public static let major: CGFloat = AureanMetrics.phiInverse
        /// The minor pane's fraction (`0.382`).
        public static let minor: CGFloat = AureanMetrics.phiInverse2
    }
}
