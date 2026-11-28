import AppKit

/// The projects list as the flow shows it: title, one sentence, the list, the footer.
struct StandardProjects: OnboardingScreenVariant {
    static let id = "projects.standard"
    static let step = OnboardingModel.Step.projects
    static let name = "Standard"
    static let summary = "Projects found from agent sessions, the best checked, then Continue."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.projectsTitle, subtitle: OnboardingStrings.projectsSubtitle,
                                body: ProjectsStepView(model: context.model.projects), context: context)
    }
}
