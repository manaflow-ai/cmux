enum TextBoxMentionKind: Equatable, Sendable {
    case file
    case skill

    var defaultTrigger: Character {
        switch self {
        case .file:
            "@"
        case .skill:
            "/"
        }
    }
}
