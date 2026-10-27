import CmuxNextComputerUse

// Computer use's live preview card in agent chats (ComputerUseLivePreview): one-line forwards to the App's owners.
extension AppServices: ComputerUseLivePreviewHost {
    func computerUsePreviewChats() -> [ComputerUsePreviewChat] { agentTabs.computerUsePreviewChats() }
    func computerUsePreviewFocusedChat() -> String? { windows.active?.focusedPane?.currentTabKey }
    func computerUsePreviewShow(_ card: ComputerUsePreviewCard?, in chat: String, respond: @escaping @MainActor (String, ComputerUsePreviewClick) -> Void) { agentTabs.showComputerUsePreview(card, in: chat, respond: respond) }
    func computerUsePreviewOpenActivity(session: String) { agentActivityPage.open(session: session) }
}
