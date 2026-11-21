import Foundation

/// The workspace Quick Terminal mark on the screen that owns it (`quick-terminal-v1`).
public struct QuickTerminalSnapshot: Sendable, Hashable, Decodable {
    public var pane: PaneID
    public var hidden: Bool
    public var from: PaneID?

    public init(pane: PaneID, hidden: Bool, from: PaneID? = nil) {
        self.pane = pane
        self.hidden = hidden
        self.from = from
    }

    enum CodingKeys: String, CodingKey { case pane, hidden, from }
}
