internal import CMUXAgentLaunch
internal import Foundation

struct AmpHookSessionRecord: Decodable {
    let sessionId: String?
    let cwd: String?
    let startedAt: TimeInterval?
    let updatedAt: TimeInterval?
    let title: String?
    let launchCommand: AgentLaunchCommand?
}

struct AmpHookSessionStoreFile: Decodable {
    let sessions: [String: AmpHookSessionRecord]

    private enum CodingKeys: String, CodingKey {
        case version
        case sessions
    }

    private struct SessionKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        let records = try container.nestedContainer(keyedBy: SessionKey.self, forKey: .sessions)
        var decoded: [String: AmpHookSessionRecord] = [:]
        decoded.reserveCapacity(records.allKeys.count)
        for key in records.allKeys {
            guard let record = try? records.decode(AmpHookSessionRecord.self, forKey: key) else {
                continue
            }
            decoded[key.stringValue] = record
        }
        sessions = decoded
    }
}
