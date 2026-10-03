import AppKit

/// The chats list as the flow shows it: title, one sentence, the list, the footer.
struct StandardChats: OnboardingScreenVariant {
    static let id = "chats.standard"
    static let step = OnboardingModel.Step.chats
    static let name = "Standard"
    static let summary = "Claude Code and Codex chats, newest first, one per line; checked ones resume in their project."
    static let surface = OnboardingSurface.fullGlass
    static let transition = OnboardingTransition.crossfade
    static func makeContent(_ context: OnboardingStepContext) -> NSView {
        OnboardingScaffold.make(title: OnboardingStrings.chatsTitle, subtitle: OnboardingStrings.chatsSubtitle,
                                body: ChatsStepView(model: context.model.chats), context: context)
    }
}
