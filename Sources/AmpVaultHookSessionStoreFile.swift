import Foundation

/// The cmux-owned Amp hook store, decoded lossily at the record boundary.
struct AmpVaultHookSessionStoreFile: Decodable {
    let sessions: [String: AmpVaultHookSessionRecord]

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
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        let records = try container.nestedContainer(keyedBy: SessionKey.self, forKey: .sessions)
        var decoded: [String: AmpVaultHookSessionRecord] = [:]
        decoded.reserveCapacity(records.allKeys.count)
        for key in records.allKeys {
            guard let record = try? records.decode(AmpVaultHookSessionRecord.self, forKey: key) else {
                continue
            }
            decoded[key.stringValue] = record
        }
        sessions = decoded
    }
}
