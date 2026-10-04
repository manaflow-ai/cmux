public import AppKit

/// How a variant's window is surfaced. Under Reduce Transparency every
/// surface draws the opaque theme background.
public enum OnboardingSurface: String, CaseIterable, Sendable {
    /// The whole window is one Liquid Glass surface, theme-tinted.
    case fullGlass
    /// A floating glass panel inset in a transparent window (desktop around it).
    case glassPanel
    /// Opaque theme background; the variant puts glass on its controls only.
    case glassControls
    /// Opaque theme background, no glass.
    case opaque
}

/// How the variant enters when its step appears.
public enum OnboardingTransition: String, CaseIterable, Sendable {
    case crossfade, slide, none
}

/// One design of one onboarding screen. A screen's variants are separate
/// types (one file each) listed in that screen's `…Variants.all`; the
/// gallery shows every one, and the flow uses the one picked per step.
@MainActor
public protocol OnboardingScreenVariant {
    /// Stable id, `<step>.<name>` ("importData.listFirst"); stored as the pick.
    static var id: String { get }
    static var step: OnboardingModel.Step { get }
    /// Gallery label and one line about the idea (developer text; the
    /// gallery is a DEBUG tool, so these are not localized).
    static var name: String { get }
    static var summary: String { get }
    static var surface: OnboardingSurface { get }
    static var transition: OnboardingTransition { get }
    /// The whole window content for the step (title, control, footer),
    /// sized by the window (`OnboardingMetrics.windowSize`).
    static func makeContent(_ context: OnboardingStepContext) -> NSView
}
