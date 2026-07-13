/// Encodes a backup record either as an authoritative iOS customization write
/// (custom keys present, including explicit null clears) or as a route/active
/// refresh (custom keys absent so the worker preserves its stored values).
struct PairedMacBackupRecordWire: Encodable {
    let record: PairedMacBackupRecord
    let includesCustomizations: Bool
    let instanceAuthority: PairedMacBackupInstanceAuthorityWriteMode

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PairedMacBackupRecord.CodingKeys.self)
        try c.encode(record.macDeviceID, forKey: .macDeviceID)
        try c.encodeIfPresent(record.displayName, forKey: .displayName)
        try c.encode(record.routes, forKey: .routes)
        try c.encode(record.createdAt, forKey: .createdAt)
        try c.encode(record.lastSeenAt, forKey: .lastSeenAt)
        try c.encode(record.isActive, forKey: .isActive)
        // Carry the phone's known identity even when the write mode tells the
        // worker to preserve or compare against its existing authority tuple.
        // Older clients omit the key, which the worker treats conservatively.
        try c.encode(record.instanceTag, forKey: .instanceTag)
        switch instanceAuthority {
        case .authoritative:
            break
        case .compareAndSet:
            try c.encode("compare_and_set", forKey: .instanceTagWriteMode)
        case .preserve:
            try c.encode("preserve", forKey: .instanceTagWriteMode)
        }
        guard includesCustomizations else { return }
        try c.encode(record.customName, forKey: .customName)
        try c.encode(record.customColor, forKey: .customColor)
        try c.encode(record.customIcon, forKey: .customIcon)
    }
}
