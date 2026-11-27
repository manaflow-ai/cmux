internal import CMUXMobileCore
import Foundation

/// `{ macDeviceID, deleted?, record? }` matching the server's parse.
struct PairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let instanceTag: String?
    let deleted: Bool?
    let reviveDeleted: Bool?
    let record: PairedMacBackupRecordWire?

    init(op: PairedMacBackupOp, routeDisclosureDate: Date = Date()) {
        switch op {
        case .upsert(let record, let instanceAuthority):
            self.macDeviceID = cmxCanonicalDeviceID(record.macDeviceID)
            self.instanceTag = record.instanceTag
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                routeDisclosureDate: routeDisclosureDate,
                instanceAuthority: instanceAuthority
            )
        case .upsertPreservingCustomizations(let record, let instanceAuthority):
            self.macDeviceID = cmxCanonicalDeviceID(record.macDeviceID)
            self.instanceTag = record.instanceTag
            self.deleted = nil
            self.reviveDeleted = nil
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                routeDisclosureDate: routeDisclosureDate,
                instanceAuthority: instanceAuthority
            )
        case .revive(let record, let instanceAuthority):
            self.macDeviceID = cmxCanonicalDeviceID(record.macDeviceID)
            self.instanceTag = record.instanceTag
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: true,
                routeDisclosureDate: routeDisclosureDate,
                instanceAuthority: instanceAuthority
            )
        case .revivePreservingCustomizations(let record, let instanceAuthority):
            self.macDeviceID = cmxCanonicalDeviceID(record.macDeviceID)
            self.instanceTag = record.instanceTag
            self.deleted = nil
            self.reviveDeleted = true
            self.record = PairedMacBackupRecordWire(
                record: record,
                includesCustomizations: false,
                routeDisclosureDate: routeDisclosureDate,
                instanceAuthority: instanceAuthority
            )
        case .delete(let macDeviceID):
            self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
            self.instanceTag = nil
            self.deleted = true
            self.reviveDeleted = nil
            self.record = nil
        case .deleteInstance(let macDeviceID, let instanceTag):
            self.macDeviceID = cmxCanonicalDeviceID(macDeviceID)
            self.instanceTag = instanceTag
            self.deleted = true
            self.reviveDeleted = nil
            self.record = nil
        }
    }
}
