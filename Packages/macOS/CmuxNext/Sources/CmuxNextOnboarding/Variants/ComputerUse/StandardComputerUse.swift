import AppKit

/// Both grants as rows under the title, Allow on each until it is Done.
struct StandardComputerUse: OnboardingScreenVariant {
    static let id = "computerUse.standard"
    static let step = OnboardingModel.Step.computerUse
    static let name = "Standard"
    static let summary = "Two grant rows, Allow then Done, drag tile over System Settings."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.computerUseTitle, subtitle: OnboardingStrings.computerUseSubtitle,
                                body: ComputerUseStepView(model: context.model.computerUse), context: context)
    }
}
