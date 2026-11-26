struct PairedMacBackupFailableRecord: Decodable {
    let value: PairedMacBackupRecord?

    init(from decoder: any Decoder) {
        value = try? PairedMacBackupRecord(from: decoder)
    }
}
