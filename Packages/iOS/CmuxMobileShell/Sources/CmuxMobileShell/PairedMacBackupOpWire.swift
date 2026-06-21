/// `{ macDeviceID, deleted?, record? }` matching the server's parse.
struct PairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let deleted: Bool?
    let record: PairedMacBackupRecord?

    init(op: PairedMacBackupOp) {
        switch op {
        case .upsert(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.record = record
        case .delete(let macDeviceID):
            self.macDeviceID = macDeviceID
            self.deleted = true
            self.record = nil
        }
    }
}
