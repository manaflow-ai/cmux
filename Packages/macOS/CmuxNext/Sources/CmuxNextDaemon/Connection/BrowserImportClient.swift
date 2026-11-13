import Foundation

/// The browser import's reads on the daemon (`browser_import.read`, the `cmux-browser-import`
/// crate): another browser's bookmarks, history, open tabs, search engine and extensions. Only the
/// verified app connection may send it; the daemon refuses a folder macOS protects, and the app
/// names a private copy instead (`ProtectedProfileCopy`).
public struct BrowserImportClient: Sendable {
    public static let capability = DaemonCapability.browserImport.rawValue
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// One read: `request` is the operation's fields as JSON (`reader` names the reader), and the
    /// reply is its result as JSON, `{ok}` or `{error: {kind, message}}`.
    public func read(_ request: Data) async throws -> Data {
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: request)
        let reply = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "browser_import.read", params: fields, idempotencyKey: nil)
        }, as: JSONValue.self, requiring: Self.capability)
        return try JSONEncoder().encode(reply)
    }
}
