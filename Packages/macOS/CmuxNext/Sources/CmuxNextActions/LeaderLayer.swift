/// The Cmd-J leader: Cmd-J arms it and the next single key runs an action.
/// Stub: no default chords yet.
public nonisolated enum LeaderLayer {
    public static let prefix = Shortcut("j", modifiers: [.command])

    /// The second key of each default leader chord, by action.
    public static let defaultChords: [(id: ActionID, key: Shortcut)] = []

    /// Sets `defaultChord` on the catalog rows `defaultChords` names.
    static func apply(to descriptors: [ActionDescriptor]) -> [ActionDescriptor] {
        descriptors
    }
}
