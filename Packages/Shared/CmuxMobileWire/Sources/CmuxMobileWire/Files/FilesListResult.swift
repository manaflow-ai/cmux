/// `files.list` result: one page of entries; `next` continues.
public struct FilesListResult: Hashable, Sendable, Codable {
    public var entries: [FilesListEntry]
    public var next: String?

    public init(entries: [FilesListEntry], next: String? = nil) {
        self.entries = entries
        self.next = next
    }
}
