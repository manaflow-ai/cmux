public import Foundation

/// The app's language on first use (`language-packs-v1`, CMUX-570): the home daemon downloads the
/// pack the app pins for a language, checks its sha256 and unpacks it into the cache, and the app
/// reads its strings from there (`Bundle.inAppLanguage`).
public struct LanguagePacksClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// What the daemon did for one language.
    public enum State: Sendable, Equatable {
        /// The app ships this language (English), or pins no pack for it: nothing to read.
        case bundled
        /// The pack is unpacked at this folder.
        case ready(root: URL)
        /// No pack this time (offline, a hash mismatch); the app keeps English.
        case unavailable(code: String, message: String)
    }

    private struct Reply: Decodable {
        var state: String
        var root: String?
        var code: String?
        var message: String?
    }

    /// Makes sure the pack for `language` is in `cache`, downloading it when it is not, and says
    /// where. Answers when the download is done (it is about half a megabyte), so the wait is long.
    public func ensure(language: String, manifest: URL, cache: URL) async throws -> State {
        let params: [String: JSONValue] = [
            "language": .string(language),
            "manifest": .string(manifest.path),
            "cache": .string(cache.path),
        ]
        let reply = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "language_packs.ensure", params: params, idempotencyKey: nil)
        }, as: Reply.self, timeout: .seconds(180), requiring: DaemonCapability.languagePacks.rawValue)
        switch reply.state {
        case "ready":
            guard let root = reply.root else { return .unavailable(code: "language_packs.io", message: "no folder") }
            return .ready(root: URL(fileURLWithPath: root, isDirectory: true))
        case "unavailable":
            return .unavailable(code: reply.code ?? "language_packs.io", message: reply.message ?? "")
        default:
            return .bundled
        }
    }
}
