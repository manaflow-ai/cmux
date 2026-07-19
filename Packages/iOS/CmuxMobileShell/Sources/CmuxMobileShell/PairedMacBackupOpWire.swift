/// `{ macDeviceID, deleted?, record? }` matching the server's parse.
struct PairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let deleted: Bool?
    let reviveDeleted: Bool?
    let record: PairedMacBackupRecordWire?

    init(op: PairedMacBackupOp) {
        switch op {
        case .upsert(let record, let instanceAuthority):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                instanceAuthority: instanceAuthority
            )
        case .upsertPreservingCustomizations(let record, let instanceAuthority):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                instanceAuthority: instanceAuthority
            )
        case .revive(let record, let instanceAuthority):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                instanceAuthority: instanceAuthority
            )
        case .revivePreservingCustomizations(let record, let instanceAuthority):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                instanceAuthority: instanceAuthority
            )
        case .delete(let macDeviceID):
            self.macDeviceID = macDeviceID
            self.deleted = true
            self.reviveDeleted = nil
            self.record = nil
        }
    }
}
