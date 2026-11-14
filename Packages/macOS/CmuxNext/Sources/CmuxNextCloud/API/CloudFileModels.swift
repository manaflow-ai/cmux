public import Foundation

/// One entry of a machine directory, as cmux-cloud-machine `models::read("file_entry")` answers it.
public struct CloudFileEntry: Sendable, Hashable, Codable {
    public var name: String
    public var kind: String
    public var size: Int64?
    public var mode: Int?
    public var modifiedAt: Date?

    public init(name: String, kind: String, size: Int64? = nil, mode: Int? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modifiedAt = modifiedAt
    }
}

/// A machine file's metadata, as cmux-cloud-machine `models::read("file_stat")` answers it.
public struct CloudFileStat: Sendable, Hashable, Codable {
    public var path: String?
    public var kind: String
    public var size: Int64?
    public var mode: Int?
    public var modifiedAt: Date?

    public init(path: String? = nil, kind: String, size: Int64? = nil, mode: Int? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modifiedAt = modifiedAt
    }
}

/// A machine file read, as cmux-cloud-machine `models::read("file_contents")` answers it. Bytes
/// stay on the authenticated route and are encoded only for the JSON transport to the app.
public struct CloudFileContents: Sendable, Hashable, Codable {
    public var path: String?
    public var dataBase64: String
    public var size: Int64?

    public init(path: String? = nil, dataBase64: String, size: Int64? = nil) {
        self.path = path
        self.dataBase64 = dataBase64
        self.size = size
    }

    public var data: Data? { Data(base64Encoded: dataBase64) }
    public var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}
