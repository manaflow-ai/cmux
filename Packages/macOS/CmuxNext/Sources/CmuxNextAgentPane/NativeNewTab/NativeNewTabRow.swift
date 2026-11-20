/// One row in the native New Tab page's dropdown (``NativeNewTabView``).
///
/// Rows are plain values: the view draws them and hands the picked one back
/// through ``NativeNewTabActions``, so no row holds the page's model.
public nonisolated enum NativeNewTabRow: Sendable, Equatable, Identifiable {
    /// Send the typed text to the agent as a new chat's first prompt.
    case ask(String)
    /// Run the typed text as a terminal command.
    case run(String)
    /// Open or search the typed text in a browser tab.
    case open(String)
    /// Jump to an open tab.
    case tab(AgentPaneOmnibar.Tab)
    /// Jump to another workspace.
    case workspace(AgentPaneOmnibar.Workspace)
    /// Open a visited page again.
    case page(AgentPaneOmnibar.Page)
    /// Run a Commands palette (Cmd-Shift-P) action.
    case action(AgentPaneOmnibar.Action)
    /// Open a chat the device's chat index lists.
    case chat(AgentPaneDeviceChat)
    /// Start an agent's chat in a folder, with no prompt ("Codex in ~/fun/cmux").
    case start(NativeNewTabStart)

    /// A key unique within one list of rows.
    public var id: String {
        switch self {
        case .ask: "ask"
        case .run: "run"
        case .open: "open"
        case .tab(let tab): "tab:\(tab.id)"
        case .workspace(let workspace): "workspace:\(workspace.id)"
        case .page(let page): "page:\(page.url)"
        case .action(let action): "action:\(action.id)"
        case .chat(let chat): "chat:\(chat.key)"
        case .start(let start): "start:\(start.harness):\(start.folder)"
        }
    }
}

/// One "Start <agent> in <folder>" row of the native New Tab page (``NativeNewTabRanker``).
public nonisolated struct NativeNewTabStart: Sendable, Equatable {
    /// The harness id (`claude`, `codex`, `opencode`).
    public var harness: String
    /// The agent's name as the row shows it.
    public var agent: String
    /// The absolute folder the chat starts in.
    public var folder: String

    public init(harness: String, agent: String, folder: String) {
        self.harness = harness
        self.agent = agent
        self.folder = folder
    }
}
