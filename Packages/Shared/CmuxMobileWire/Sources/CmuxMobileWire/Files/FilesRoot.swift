/// A directory the Mac lets this device browse (`files.roots`).
public struct FilesRoot: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// Absolute canonical path on the Mac.
    public var path: String
    public var writable: Bool

    public init(id: String, name: String, path: String, writable: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.writable = writable
    }
}
