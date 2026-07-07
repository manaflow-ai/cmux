struct ChatBlockDetail: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let sections: [ChatBlockDetailSection]

    var copyText: String {
        sections
            .map(\.text)
            .joined(separator: "\n\n")
    }
}
