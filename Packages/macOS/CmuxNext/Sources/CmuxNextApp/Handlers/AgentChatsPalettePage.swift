import CmuxNextAgentLanes
import CmuxNextPalette

extension AgentChatsPalettePage {
    /// The chats page over the app's feed: the palette's choice history of chats ranks it, and a
    /// row opens through the app's Open Chat path.
    init(services: AppServices) {
        self.init(windows: services.chatsFeed?.windows,
                  history: { [weak services] query in
                      guard let model = services?.palette.model else { return nil }
                      return model.frecency.rankerHistory(keyPrefix: "chat:", query: query, now: model.now())
                  },
                  open: { [weak services] key in services?.chatsOpener.open(key) })
    }
}
