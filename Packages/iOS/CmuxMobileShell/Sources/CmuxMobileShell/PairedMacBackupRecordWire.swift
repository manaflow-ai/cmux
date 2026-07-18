/// Encodes a backup record either as an authoritative iOS customization write
/// (custom keys present, including explicit null clears) or as a route/active
/// refresh (custom keys absent so the worker preserves its stored values).
struct PairedMacBackupRecordWire: Encodable {
    let record: PairedMacBackupRecord
    let includesCustomizations: Bool

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PairedMacBackupRecord.CodingKeys.self)
        try c.encode(record.macDeviceID, forKey: .macDeviceID)
        try c.encodeIfPresent(record.displayName, forKey: .displayName)
        try c.encode(record.routes, forKey: .routes)
        try c.encode(record.createdAt, forKey: .createdAt)
        try c.encode(record.lastSeenAt, forKey: .lastSeenAt)
        try c.encode(record.isActive, forKey: .isActive)
        guard includesCustomizations else { return }
        try c.encode(record.customName, forKey: .customName)
        try c.encode(record.customColor, forKey: .customColor)
        try c.encode(record.customIcon, forKey: .customIcon)
    }
}
