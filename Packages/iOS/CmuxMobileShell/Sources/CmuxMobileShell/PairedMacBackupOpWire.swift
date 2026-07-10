import Foundation

/// `{ macDeviceID, deleted?, record? }` matching the server's parse.
struct PairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let deleted: Bool?
    let reviveDeleted: Bool?
    let record: PairedMacBackupRecordWire?

    init(op: PairedMacBackupOp, routeDisclosureDate: Date) {
        switch op {
        case .upsert(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                routeDisclosureDate: routeDisclosureDate
            )
        case .upsertPreservingCustomizations(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                routeDisclosureDate: routeDisclosureDate
            )
        case .revive(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                routeDisclosureDate: routeDisclosureDate
            )
        case .revivePreservingCustomizations(let record):
            self.macDeviceID = record.macDeviceID
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                routeDisclosureDate: routeDisclosureDate
            )
        case .delete(let macDeviceID):
            self.macDeviceID = macDeviceID
            self.deleted = true
            self.reviveDeleted = nil
            self.record = nil
        }
    }
}
