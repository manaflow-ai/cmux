import AppKit

/// Two task cards; the picked task's live chat and saved files replace them.
struct StandardFirstTask: OnboardingScreenVariant {
    static let id = "firstTask.standard"
    static let step = OnboardingModel.Step.firstTask
    static let name = "Standard"
    static let summary = "Two task cards, then the task running in a real chat with its saved files."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.firstTaskTitle, subtitle: OnboardingStrings.firstTaskSubtitle,
                                body: FirstTaskStepView(model: context.model.firstTask, services: context.services), context: context)
    }
}
