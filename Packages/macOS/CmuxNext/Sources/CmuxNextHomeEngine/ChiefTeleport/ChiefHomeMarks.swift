public import Foundation

/// Everything a Chief home's `state` folder says about moves (the Teleport chip, menu and chat row
/// read it): where the Chief went and when (`moved.json`), a move that runs now (`moving.json`),
/// and its fork in cmux Cloud (`fork.json`).
///
/// ```swift
/// let marks = await ChiefLocationReader().marks(home: temporaryHome)
/// marks.moving?.to // .cloud while `cmux chief move --to cloud` runs
/// ```
public nonisolated struct ChiefHomeMarks: Equatable, Sendable {
    /// Where the Chief went (``ChiefWhereabouts/thisMac`` with no marker).
    public var whereabouts: ChiefWhereabouts
    /// When the move that wrote `moved.json` ended; nil with no marker or no readable date.
    public var movedAt: Date?
    /// The move that runs now; nil when none runs (no hold, or its process is gone).
    public var moving: ChiefMoveHold?
    /// This Chief's fork in cmux Cloud; nil when it has none.
    public var fork: ChiefForkRecord?

    /// No marks: the Chief runs here, nothing moves, no fork.
    public static let none = ChiefHomeMarks(whereabouts: .thisMac, movedAt: nil, moving: nil, fork: nil)

    public init(whereabouts: ChiefWhereabouts, movedAt: Date?, moving: ChiefMoveHold?, fork: ChiefForkRecord?) {
        self.whereabouts = whereabouts
        self.movedAt = movedAt
        self.moving = moving
        self.fork = fork
    }

    /// The marks three files name.
    ///
    /// - Parameters:
    ///   - movedJSON: `state/moved.json`, nil when there is none.
    ///   - movingJSON: `state/moving.json`, nil when there is none.
    ///   - forkJSON: `state/fork.json`, nil when there is none.
    ///   - isRunning: Whether a pid runs; a hold whose mover is gone is dropped.
    public init(movedJSON: Data?, movingJSON: Data?, forkJSON: Data?, isRunning: (Int32) -> Bool) {
        whereabouts = ChiefWhereabouts(movedJSON: movedJSON)
        movedAt = whereabouts.location == .thisMac ? nil : ChiefWhereabouts.date(movedJSON: movedJSON)
        moving = ChiefMoveHold(json: movingJSON).flatMap { isRunning($0.pid) ? $0 : nil }
        fork = ChiefForkRecord(json: forkJSON)
    }
}
