struct CodeHighlightRequest: Identifiable, Sendable, Hashable {
    let id: String
    let language: String?
    let line: String
    let colorScheme: DiffColorScheme
}
