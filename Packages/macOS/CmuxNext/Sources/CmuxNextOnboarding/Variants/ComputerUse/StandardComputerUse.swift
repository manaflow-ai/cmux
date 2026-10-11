import AppKit

/// Computer Use setup: both grants as rows under the title, Allow on each
/// until it is Done.
struct StandardComputerUse: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.computerUse
    static let surface = OnboardingSurface.fullGlass
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.computerUseTitle, subtitle: OnboardingStrings.computerUseSubtitle,
                                body: ComputerUseStepView(model: context.model.computerUse), context: context)
    }
}
