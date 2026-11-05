public import Foundation

/// Reads where a Chief runs from its home's `state/moved.json` (``ChiefLocation``), off the main thread.
///
/// Tests pass a temporary folder as the home:
///
/// ```swift
/// let location = await ChiefLocationReader().read(home: temporaryHome)
/// ```
public nonisolated struct ChiefLocationReader: Sendable {
    /// The engine's marker, relative to a Chief home (optchat-chief migrate.rs `MOVED_FILE`).
    public static let movedFile = "state/moved.json"

    public init() {}

    /// The location `home`'s marker names; This Mac when there is none.
    ///
    /// - Parameter home: A Chief home (`ChiefHome.root`).
    /// - Returns: Where that Chief runs now.
    public func read(home: URL) async -> ChiefLocation {
        await whereabouts(home: home).location
    }

    /// Where `home`'s marker says the Chief went, with the hosted Chief's agent id for cmux Cloud.
    ///
    /// - Parameter home: A Chief home (`ChiefHome.root`).
    public func whereabouts(home: URL) async -> ChiefWhereabouts {
        let file = home.appendingPathComponent(Self.movedFile)
        // One small file read, at the person's priority, never on the main actor.
        let data = await Task.detached(priority: .userInitiated) { try? Data(blockingContentsOf: file) }.value
        return ChiefWhereabouts(movedJSON: data)
    }
}
