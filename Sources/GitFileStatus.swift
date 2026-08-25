enum GitFileStatus: Equatable {
    case modified, added, deleted, renamed, untracked

    var indicator: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }
}
