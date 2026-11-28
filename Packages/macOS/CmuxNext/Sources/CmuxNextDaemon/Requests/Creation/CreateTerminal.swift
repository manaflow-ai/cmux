import Foundation

// create-terminal's request is generated (swift_app bindings.json, Creation); its replies stay hand-written.

/// `{surface}` plus the terminal identity newer servers add.
public struct SurfaceCreated: Decodable, Sendable, Equatable {
    public var surface: SurfaceID
    public var terminalID: TerminalID?
    public var terminalIncarnation: TerminalIncarnation?

    init(surface: SurfaceID, terminalID: TerminalID? = nil, terminalIncarnation: TerminalIncarnation? = nil) {
        self.surface = surface
        self.terminalID = terminalID
        self.terminalIncarnation = terminalIncarnation
    }

    enum CodingKeys: String, CodingKey {
        case surface
        case terminalID = "terminal_id"
        case terminalIncarnation = "terminal_incarnation"
    }
}

public struct CreateTerminalResult: Decodable, Sendable, Equatable {
    public var surface: SurfaceID?
    public var terminalID: TerminalID
    public var terminalIncarnation: TerminalIncarnation?
    public var pane: PaneID?
    public var screen: ScreenID?
    public var workspace: WorkspaceHandle?
    public var key: WorkspaceKey
    public var lifecycle: String
    public var alreadyExited: Bool?
    public var terminalRevision: UInt64?
    public var replayed: Bool

    enum CodingKeys: String, CodingKey {
        case surface, pane, screen, workspace, key, lifecycle, replayed
        case terminalID = "terminal_id"
        case terminalIncarnation = "terminal_incarnation"
        case alreadyExited = "already_exited"
        case terminalRevision = "terminal_revision"
    }
}
