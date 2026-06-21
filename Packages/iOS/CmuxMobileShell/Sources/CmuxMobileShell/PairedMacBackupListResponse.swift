struct PairedMacBackupListResponse: Decodable {
    let records: [PairedMacBackupRecord]

    private enum CodingKeys: String, CodingKey {
        case records
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        records = try c.decode([PairedMacBackupFailableRecord].self, forKey: .records)
            .compactMap(\.value)
    }
}
