struct ChatBlockDetailSection: Identifiable, Equatable {
    enum Style: Equatable {
        case prose
        case monospaced
    }

    let id: String
    let title: String
    let text: String
    let style: Style
}
