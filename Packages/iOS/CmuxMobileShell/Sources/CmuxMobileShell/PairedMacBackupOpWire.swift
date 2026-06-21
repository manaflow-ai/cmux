/// `{ macDeviceID, deleted?, record? }` matching the server's parse.
struct PairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let deleted: Bool?
    let reviveDeleted: Bool?
    let record: PairedMacBackupRecord?

    init(op: PairedMacBackupOp) {
        switch op {
        case .upsert(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = record
        case .revive(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = true
            self.record = record
        case .delete(let macDeviceID):
            self.macDeviceID = macDeviceID
            self.deleted = true
            self.reviveDeleted = nil
            self.record = nil
        }
    }
}
