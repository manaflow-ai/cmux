import AppKit

/// The default classic cmux import screen.
struct StandardClassicSessions: OnboardingScreenVariant {
    static let id = "classicSessions.standard"
    static let step = OnboardingModel.Step.classicSessions
    static let name = "Standard"
    static let summary = "Import classic cmux workspaces, tabs and layout."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView { OnboardingScaffold.make(title: OnboardingStrings.classicSessionsTitle, subtitle: OnboardingStrings.classicSessionsSubtitle, body: ClassicSessionsStepView(model: context.model.classicSessions), context: context) }
}
