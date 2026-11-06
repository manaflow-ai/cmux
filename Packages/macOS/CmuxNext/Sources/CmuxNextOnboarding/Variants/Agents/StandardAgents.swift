import AppKit

/// Agents (first run): leading title and line, a card per installed agent CLI with its
/// sign-in, then Skip and Continue, on full-window glass.
struct StandardAgents: OnboardingScreenVariant {
    static let step = OnboardingModel.Step.agents
    static let surface = OnboardingSurface.fullGlass
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        let model = context.model.agents
        let body = AgentsStepView(model: model) { [weak model] agent in model?.source?.agentIcon(agent, side: AgentSignInRow.iconSide) }
        return OnboardingScaffold.make(title: OnboardingStrings.agentsHeading, subtitle: OnboardingStrings.agentsBody,
                                       body: body, context: context)
    }
}
