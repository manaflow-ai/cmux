struct MobileDiffsTestRequest: Sendable, Equatable {
    let method: String?
    let id: String?
    let workspaceRef: String?
    let baseKind: String?
    let baseValue: String?
    let ignoreWhitespace: Bool?
    let path: String?
    let oldPath: String?
    let cursor: Int?
    let force: Bool?
    let startLine: Int?
    let endLine: Int?
}
