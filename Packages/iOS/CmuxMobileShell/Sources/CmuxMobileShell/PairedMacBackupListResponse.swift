internal import CmuxMobilePairedMac
import Foundation

struct PairedMacBackupListResponse: Decodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]
    /// The server-owned collection revision used for conditional migration writes.
    let revision: Int?
    /// The presence worker's echo of the verified team this collection was read
    /// from; nil when the worker predates the echo.
    let teamId: String?

    var snapshot: PairedMacBackupSnapshot {
        PairedMacBackupSnapshot(
            records: records,
            deletedMacDeviceIDs: deletedMacDeviceIDs,
            resolvedTeamID: teamId
        )
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case deletedMacDeviceIDs
        case revision
        case teamId
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([PairedMacBackupFailableRecord].self, forKey: .records)
            .compactMap(\.value)
        deletedMacDeviceIDs = ((try? c.decodeIfPresent([String].self, forKey: .deletedMacDeviceIDs)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { pairingID in
                let identity = MobilePairedMac.pairingIdentity(from: pairingID)
                return MobilePairedMac.pairingID(
                    macDeviceID: identity.macDeviceID,
                    instanceTag: identity.instanceTag
                )
            }
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        let trimmedTeamID = ((try? c.decodeIfPresent(String.self, forKey: .teamId)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        teamId = (trimmedTeamID?.isEmpty ?? true) ? nil : trimmedTeamID
    }
}
