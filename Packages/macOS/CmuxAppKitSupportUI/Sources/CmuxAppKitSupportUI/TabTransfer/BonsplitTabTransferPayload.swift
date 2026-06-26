public import Foundation

/// Pure `Codable` value mirror of `Bonsplit.TabTransferData`.
///
/// Wraps a ``BonsplitTabItemPayload`` plus the source pane/process identity and
/// is the top-level object encoded as the `com.splittabbar.tabtransfer` drag
/// payload. The JSON keys are these property names, so they must stay
/// byte-faithful to bonsplit's `TabTransferData` decoder.
public struct BonsplitTabTransferPayload: Codable, Sendable {
    /// The dragged tab's payload.
    public let tab: BonsplitTabItemPayload
    /// Identity of the pane the tab is dragged from.
    public let sourcePaneId: UUID
    /// PID of the process that originated the drag.
    public let sourceProcessId: Int32

    /// Memberwise initializer (public so the app target can build the payload).
    public init(tab: BonsplitTabItemPayload, sourcePaneId: UUID, sourceProcessId: Int32) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    /// Encode as the JSON blob bonsplit's external-drop decoder accepts.
    ///
    /// Returns `nil` when encoding fails, matching the legacy `try?` behavior.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
