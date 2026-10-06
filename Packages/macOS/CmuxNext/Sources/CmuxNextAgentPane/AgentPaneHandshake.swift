public import Foundation

/// The versioned host handshake: the one value Swift hands the React agent
/// pane (`webviews/src/agent-session/acpmux`). Everything above it, the
/// acpmux WebSocket protocol, session state and rendering, is TypeScript.
///
/// The page asks for it with `ready` over the `agentSession` message handler.
/// The page never gets the daemon's endpoint or either token: the host owns
/// the socket (``AgentPaneTransport``) and the page talks to it through the
/// bridge (`transport.open`, `transport.send`, `transport.close`). Field names
/// match the TypeScript `AcpmuxHostConfig`; bump ``currentVersion`` for any
/// change a page of the old version would misread.
public nonisolated struct AgentPaneHandshake: Codable, Sendable, Equatable {
    /// 2: the socket moved to the host (`acpmux-bridge`); no endpoint or token.
    public static let currentVersion = 2

    public nonisolated enum Transport: String, Codable, Sendable {
        /// acpmux through the host's socket and the page bridge.
        case acpmuxBridge = "acpmux-bridge"
        /// No daemon: the page runs its in-memory mock transcript.
        case mock
    }

    /// The coded fields: everything but ``connection``, which never reaches the page.
    private enum CodingKeys: String, CodingKey {
        case protocolVersion, transport, sessionId, newSession, newTab, cwd, draft, prompt, harness, adopt, surface,
             linkScheme, sessionMustExist, revealTurn, chooseFolder
    }

    public var protocolVersion: Int
    public var transport: Transport
    /// The host's socket to open on `transport.open`. Not coded: the page never sees it.
    public var connection: AcpmuxConnection? = nil
    /// The session this pane shows, if it has one.
    public var sessionId: String?
    /// True for a pane opened as a new chat: the page does not fall back to
    /// the most recent session and creates one on the first prompt.
    public var newSession: Bool?
    /// Set for a tab opened as the new tab page; the page shows it until
    /// the tab becomes a chat, a terminal or a browser.
    public var newTab: AgentPaneNewTab?
    /// A new chat's working directory, sent with `session/new` (#16620).
    /// Pages that predate it ignore it, so the version stays the same.
    public var cwd: String?
    /// Text a new chat's composer starts with. Shown, never sent by itself.
    public var draft: String?
    /// A new chat's first prompt, sent by the page once it connects.
    /// Pages that predate it ignore it (the chat just stays empty).
    public var prompt: String?
    /// The harness a new chat starts on before `prompt` is sent. Pages that
    /// predate it ignore it (the chat starts on the default harness).
    public var harness: String?
    /// An outside chat the page resumes on connect. Pages that predate it
    /// ignore it and open an empty chat, so the version stays the same.
    public var adopt: AgentPaneAdopt?
    /// Where the page is shown when it is not a pane tab (`"quick"`: the
    /// quick panel's compact composer). Pages that predate it ignore it.
    public var surface: AgentPaneSurface?
    /// This build's URL scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`), for
    /// the links the page copies (`links.ts` `sessionLink`). Pages that
    /// predate it ignore it.
    public var linkScheme: String?
    /// True for a tab a `cmux://session/<id>` link opened: `sessionId`
    /// must exist. When the daemon has no such session the page says so
    /// instead of falling back to the most recent one, and marks nothing
    /// seen. Pages that predate it fall back as before.
    public var sessionMustExist: Bool?
    /// The turn a `cmux://session/<id>#turn-<turnId>` link names: the page
    /// scrolls to it once its row renders, and gives up quietly after a few
    /// seconds. Handed out once.
    public var revealTurn: String?
    /// True for a new chat in a workspace without a folder: it starts in the workspace's
    /// agent-home folder, and the page offers "Choose Folder…" (`workspace.chooseFolder`,
    /// AGENT-CWD-FOR-FOLDERLESS-WORKSPACE). Pages that predate it ignore it.
    public var chooseFolder: Bool?

    public init(transport: Transport, connection: AcpmuxConnection? = nil, sessionId: String? = nil, newSession: Bool? = nil) {
        protocolVersion = Self.currentVersion
        self.transport = transport
        self.connection = connection
        self.sessionId = sessionId
        self.newSession = newSession
    }

    public static let mock = AgentPaneHandshake(transport: .mock)

    /// A handshake for a live daemon: the page gets the bridge transport, the host keeps `connection`.
    public static func acpmux(_ connection: AcpmuxConnection, sessionId: String?) -> AgentPaneHandshake {
        AgentPaneHandshake(transport: .acpmuxBridge, connection: connection,
                           sessionId: sessionId, newSession: sessionId == nil ? true : nil)
    }
}
