public import AppKit

/// How a screen's window is surfaced. Under Reduce Transparency every
/// surface draws the opaque theme background.
public enum OnboardingSurface: String, CaseIterable, Sendable {
    /// The whole window is one Liquid Glass surface, theme-tinted.
    case fullGlass
    /// A floating glass panel inset in a transparent window (desktop around it).
    case glassPanel
    /// Opaque theme background, no glass.
    case opaque
}

/// The screen of one tool window step: its surface and its content.
@MainActor
public protocol OnboardingScreenVariant {
    static var step: OnboardingModel.Step { get }
    static var surface: OnboardingSurface { get }
    /// The whole window content for the step (title, control, footer),
    /// sized by the window (`OnboardingMetrics.windowSize`).
    static func makeContent(_ context: OnboardingStepContext) -> NSView
}
