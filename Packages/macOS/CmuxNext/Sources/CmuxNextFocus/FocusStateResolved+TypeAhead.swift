extension FocusState.Resolved {
    /// Pages whose keys may wait for their document: agent pages (the new
    /// tab page, chats) and React pages (CmuxNextPages).
    public var mayQueueTyping: Bool {
        switch self {
        case .agentPage, .page: true
        default: false
        }
    }
}
