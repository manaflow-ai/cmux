public import Foundation

/// A move that runs now, as its home's `state/moving.json` says (optchat-chief migrate.rs
/// `hold_for_move`): the mover's pid, when it started and the target it goes to. The engine
/// removes the file when the move ends; a file whose pid is gone is a move that died, not one
/// that runs (``ChiefLocationReader`` drops it).
public nonisolated struct ChiefMoveHold: Equatable, Sendable {
    /// The `optchat-chief move` process that holds the home.
    public var pid: Int32
    /// Where the move goes; nil for an engine that does not write it.
    public var to: ChiefLocation?

    public init(pid: Int32, to: ChiefLocation?) {
        self.pid = pid
        self.to = to
    }

    /// The hold a `moving.json` names; nil for no file or one that is not the engine's hold.
    ///
    /// - Parameter json: The file's bytes.
    public init?(json: Data?) {
        guard let json, let file = try? JSONDecoder().decode(File.self, from: json), file.pid > 0 else { return nil }
        pid = file.pid
        to = file.to.map { ChiefLocation(movedTo: $0) }
    }

    private struct File: Decodable {
        var pid: Int32
        var to: String?
    }
}
