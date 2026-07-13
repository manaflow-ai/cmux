enum BaselineEntryKind: Equatable {
    case missing
    case file
    case gitlink
    case directory

    var isFile: Bool {
        self == .file || self == .gitlink
    }

    var excludesDescendants: Bool {
        self == .file || self == .directory
    }
}
