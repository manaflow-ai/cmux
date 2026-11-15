/// What the native New Tab page asks its host to do (``NativeNewTabModel``).
///
/// A closure bundle: the page never holds the app's services. The app builds one per page
/// (`NewTabPage.nativeActions`) over the same paths the web page's requests take.
public struct NativeNewTabActions {
    /// Submit `text` as the page would: `search` true searches it on the web. The host classifies
    /// it (a URL opens, `!` makes a terminal, else a prompt starts a chat) with the shared table.
    public var submit: @MainActor (_ text: String, _ kind: AgentPaneTabKind, _ search: Bool) -> Void
    /// Jump to an open tab or another workspace.
    public var jump: @MainActor (AgentPaneJumpTarget, String) -> Void
    /// Run a Commands palette action by id, as the palette runs it.
    public var action: @MainActor (String) -> Void
    /// Open a device chat by its index key (`harness:sessionId`), on the Chats feed's Open Chat path.
    public var openChat: @MainActor (String) -> Void
    /// Start harness `harness`'s chat in absolute folder `folder`, with no prompt (as New chat there;
    /// the agent tab asks about a folder not trusted yet); the page closes, as at a submit.
    public var start: @MainActor (_ harness: String, _ folder: String) -> Void

    /// Creates the bundle.
    /// - Parameters:
    ///   - submit: Submits typed text for a kind.
    ///   - jump: Jumps to a tab or workspace.
    ///   - action: Runs a Commands palette action.
    ///   - openChat: Opens a device chat.
    ///   - start: Starts an agent's chat in a folder.
    public init(submit: @escaping @MainActor (String, AgentPaneTabKind, Bool) -> Void = { _, _, _ in },
                jump: @escaping @MainActor (AgentPaneJumpTarget, String) -> Void = { _, _ in },
                action: @escaping @MainActor (String) -> Void = { _ in },
                openChat: @escaping @MainActor (String) -> Void = { _ in },
                start: @escaping @MainActor (String, String) -> Void = { _, _ in }) {
        self.submit = submit
        self.jump = jump
        self.action = action
        self.openChat = openChat
        self.start = start
    }
}
