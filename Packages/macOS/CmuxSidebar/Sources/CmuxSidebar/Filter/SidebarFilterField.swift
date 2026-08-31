/// One searchable text field on a sidebar workspace row.
///
/// The sidebar filter scores a query against the fields a row can display, so
/// typing a branch name finds a workspace whose title says nothing about the
/// branch. Fields are tried in ``matchPriority`` order and the first hit wins.
public enum SidebarFilterField: String, CaseIterable, Sendable, Hashable {
    /// The workspace's displayed title (custom or auto-derived).
    case title
    /// The workspace's git branch.
    case branch
    /// The workspace's working directory path.
    case directory
    /// The name of the group the workspace belongs to.
    case group
    /// The linked pull request's number and title.
    case pullRequest
    /// A port the workspace is listening on.
    case port

    /// Priority of this field when a row matches on more than one.
    ///
    /// Fields are scored in descending priority and the first hit wins, so a
    /// row that matches on its title never pays to score its directory. That
    /// is both faster and more predictable than taking the maximum score
    /// across fields: "the title matched" always beats "the path happened to
    /// contain those letters", regardless of how the fuzzy scores compare.
    ///
    /// Ranking between rows is lexicographic on `(matchPriority, fuzzyScore)`.
    public var matchPriority: Int {
        switch self {
        case .title:
            return 60
        case .branch:
            return 50
        case .directory:
            return 40
        case .group:
            return 30
        case .pullRequest:
            return 20
        case .port:
            return 10
        }
    }

    /// Every field in the order the filter scores them.
    public static var scoringOrder: [SidebarFilterField] {
        allCases.sorted { $0.matchPriority > $1.matchPriority }
    }

    /// The single-character prefix that restricts a query to this field, if any.
    ///
    /// Typing `@main` searches branches only; `#infra` searches group names;
    /// `:3000` searches ports; `/repos` searches directories. Titles have no
    /// sigil because an unprefixed query already searches every field.
    public var querySigil: Character? {
        switch self {
        case .branch:
            return "@"
        case .group:
            return "#"
        case .port:
            return ":"
        case .directory:
            return "/"
        case .title, .pullRequest:
            return nil
        }
    }
}
