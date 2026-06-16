import Foundation

struct AmpHookSessionStoreFile: Decodable {
    var sessions: [String: AmpHookSessionRecord]

    private enum CodingKeys: String, CodingKey { case sessions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.sessions) else {
            sessions = [:]
            return
        }
        // Decode entry-by-entry so one type-drifted record (this is persisted
        // cross-version state) can't blank the whole listing.
        let sessionsContainer = try container.nestedContainer(
            keyedBy: AmpHookSessionStoreKey.self,
            forKey: .sessions
        )
        var decoded: [String: AmpHookSessionRecord] = [:]
        decoded.reserveCapacity(sessionsContainer.allKeys.count)
        for key in sessionsContainer.allKeys {
            guard let record = try? sessionsContainer.decode(
                AmpHookSessionRecord.self,
                forKey: key
            ) else { continue }
            decoded[key.stringValue] = record
        }
        sessions = decoded
    }
}
