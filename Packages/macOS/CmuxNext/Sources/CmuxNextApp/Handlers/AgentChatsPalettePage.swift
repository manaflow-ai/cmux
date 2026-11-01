import CmuxNextAgentLanes
import CmuxNextPalette

extension AgentChatsPalettePage {
    /// The chats page over the app's feed: the palette's choice history of chats ranks it, and a
    /// row opens through the app's Open Chat path.
    init(services: AppServices) {
        self.init(windows: services.chatsFeed?.windows,
                  history: { [weak services] query in await services?.palette.model.rankerHistory(keyPrefix: "chat:", query: query) },
                  open: { [weak services] key in services?.chatsOpener.open(key) })
    }
}
