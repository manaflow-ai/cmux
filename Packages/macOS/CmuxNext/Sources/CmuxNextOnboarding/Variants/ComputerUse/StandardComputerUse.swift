import AppKit

/// Computer Use setup: both grants as cards under the title, Allow on each
/// until it is Allowed. The window fits its two cards and one note: at the
/// shared 520 pt it was half empty (user 2026-10-27, "improve this ui").
struct StandardComputerUse: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.computerUse
    static let surface = OnboardingSurface.fullGlass
    static let windowSize = OnboardingMetrics.computerUseWindowSize
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.computerUseTitle, subtitle: OnboardingStrings.computerUseSubtitle,
                                body: ComputerUseStepView(model: context.model.computerUse), context: context)
    }
}
