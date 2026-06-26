import Foundation

/// Decodable shape of the Grok agent hook store file (`grok-hook-sessions.json`),
/// used to recover observed `GROK_HOME` values from previously launched sessions.
///
/// These are the closed set of decode-only DTOs read by
/// `GrokSessionLocator.observedGrokHomes(hookStoreFileURL:fileManager:)`; only the
/// `launchCommand.environment` map is consulted.
struct GrokHookObservedSessionStoreFile: Decodable {
    var sessions: [String: GrokHookObservedSessionRecord]

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(
            [String: GrokHookObservedSessionRecord].self,
            forKey: .sessions
        ) ?? [:]
    }
}

struct GrokHookObservedSessionRecord: Decodable {
    var launchCommand: GrokHookObservedLaunchCommand?
}

struct GrokHookObservedLaunchCommand: Decodable {
    var environment: [String: String]?
}
