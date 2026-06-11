enum RenderableWorkspaceGroupIcon: Equatable {
    case systemSymbol(String)
    case emoji(String)

    var rawValue: String {
        switch self {
        case .systemSymbol(let symbol), .emoji(let symbol):
            return symbol
        }
    }
}
