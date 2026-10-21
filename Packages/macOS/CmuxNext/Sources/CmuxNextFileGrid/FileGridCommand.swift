/// Everything a person can do to a grid's selected files. The context menu,
/// the keys (Space, Return, Cmd-O, Cmd-C, Cmd-Option-C, Cmd-Delete) and a
/// double click all name one of these and reach the grid owner's one
/// `perform` path, so an entrypoint cannot drift from the others.
public nonisolated enum FileGridCommand: String, Sendable, CaseIterable, Hashable {
    /// Opens the files in their default apps (double click, Cmd-O, Cmd-Down).
    case open
    /// Shows the Quick Look panel (Space).
    case quickLook
    /// Selects the files in Finder.
    case reveal
    /// Copies the files (Cmd-C).
    case copy
    /// Copies the files' paths as text (Cmd-Option-C).
    case copyPath
    /// Renames the one selected file (Return).
    case rename
    /// Moves the files to the Trash (Cmd-Delete).
    case trash

    /// Whether the command applies to this many selected files.
    ///
    /// - Parameter count: the selection's size.
    public func applies(toSelectionOf count: Int) -> Bool {
        switch self {
        case .rename: count == 1
        default: count > 0
        }
    }

    /// The commands of the context menu, in order, with a separator before each nil.
    public static let menuOrder: [FileGridCommand?] = [.open, .quickLook, nil, .reveal, .copy, .copyPath, nil, .rename, .trash]
}
