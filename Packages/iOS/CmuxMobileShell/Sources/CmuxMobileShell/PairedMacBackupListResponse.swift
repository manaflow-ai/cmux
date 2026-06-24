import Foundation

struct PairedMacBackupListResponse: Decodable {
    let records: [PairedMacBackupRecord]
    let deletedMacDeviceIDs: [String]

    var snapshot: PairedMacBackupSnapshot {
        PairedMacBackupSnapshot(records: records, deletedMacDeviceIDs: deletedMacDeviceIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case deletedMacDeviceIDs
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([PairedMacBackupFailableRecord].self, forKey: .records)
            .compactMap(\.value)
        deletedMacDeviceIDs = ((try? c.decodeIfPresent([String].self, forKey: .deletedMacDeviceIDs)) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
