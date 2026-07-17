struct IntralineToken: Sendable, Equatable {
    enum Category: Sendable, Equatable {
        case word
        case whitespace
        case punctuation
    }

    let text: String
    let category: Category
    let range: TextRange
}
