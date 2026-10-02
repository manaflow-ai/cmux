import AppKit

/// The role grid as the flow shows it: title, one sentence, the grid, the footer.
struct StandardRole: OnboardingScreenVariant {
    static let id = "role.standard"
    static let step = OnboardingModel.Step.role
    static let name = "Standard"
    static let summary = "Role grid, a line of your own, then Continue."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.roleTitle, subtitle: OnboardingStrings.roleSubtitle,
                                body: RoleStepView(model: context.model.role), context: context)
    }
}
