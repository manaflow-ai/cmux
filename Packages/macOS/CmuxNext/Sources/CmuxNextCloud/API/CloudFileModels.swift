public import Foundation

/// Entry returned by the backend-wrapped Cloud VM filesystem directory operation.
public struct CloudFileEntry: Sendable, Hashable, Decodable {
    public var name: String
    public var kind: String
    public var size: Int64?
    public var mode: Int?
    public var modifiedAt: Date?

    enum CodingKeys: String, CodingKey { case name, kind, size, mode, modifiedAt }

    public init(name: String, kind: String, size: Int64? = nil, mode: Int? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modifiedAt = modifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "file"
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        mode = try c.decodeIfPresent(Int.self, forKey: .mode)
        modifiedAt = try c.decodeIfPresent(Double.self, forKey: .modifiedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Metadata returned by the backend-wrapped Cloud VM filesystem stat operation.
public struct CloudFileStat: Sendable, Hashable, Decodable {
    public var path: String?
    public var kind: String
    public var size: Int64?
    public var mode: Int?
    public var modifiedAt: Date?

    enum CodingKeys: String, CodingKey { case path, kind, isDirectory, size, mode, modifiedAt }

    public init(path: String? = nil, kind: String, size: Int64? = nil, mode: Int? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mode = mode
        self.modifiedAt = modifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        if let kind = try c.decodeIfPresent(String.self, forKey: .kind) {
            self.kind = kind
        } else {
            self.kind = (try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false) ? "directory" : "file"
        }
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        mode = try c.decodeIfPresent(Int.self, forKey: .mode)
        modifiedAt = try c.decodeIfPresent(Double.self, forKey: .modifiedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

/// Backend response for a file read. Bytes stay on the authenticated backend
/// route and are encoded only for the JSON transport to the app.
public struct CloudFileContents: Sendable, Hashable, Decodable {
    public var path: String?
    public var dataBase64: String
    public var size: Int64?

    enum CodingKeys: String, CodingKey { case path, dataBase64, data, size }

    public init(path: String? = nil, dataBase64: String, size: Int64? = nil) {
        self.path = path
        self.dataBase64 = dataBase64
        self.size = size
    }

    public var data: Data? { Data(base64Encoded: dataBase64) }
    public var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        dataBase64 = try c.decodeIfPresent(String.self, forKey: .dataBase64)
            ?? c.decode(String.self, forKey: .data)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
    }
}

/// A short-lived private route for an SCP transfer. The private key remains
/// on the caller; only its public half is sent to the backend.
public struct CloudSCPEndpoint: Sendable, Hashable, Decodable {
    public var host: String
    public var port: Int
    public var username: String
    public var hostPublicKey: String
    public var expiresAtUnix: Int64

    enum CodingKeys: String, CodingKey { case host, port, username, hostPublicKey, hostPublicKeySnake = "host_public_key", expiresAtUnix, expiresAtUnixSnake = "expires_at_unix" }

    public init(host: String, port: Int, username: String, hostPublicKey: String, expiresAtUnix: Int64) {
        self.host = host
        self.port = port
        self.username = username
        self.hostPublicKey = hostPublicKey
        self.expiresAtUnix = expiresAtUnix
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        hostPublicKey = try c.decodeIfPresent(String.self, forKey: .hostPublicKey)
            ?? c.decode(String.self, forKey: .hostPublicKeySnake)
        expiresAtUnix = try c.decodeIfPresent(Int64.self, forKey: .expiresAtUnix)
            ?? c.decode(Int64.self, forKey: .expiresAtUnixSnake)
    }
}
