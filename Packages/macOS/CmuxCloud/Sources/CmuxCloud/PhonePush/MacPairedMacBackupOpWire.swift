public struct MacPairedMacBackupOpWire: Encodable, Sendable {
    public init(
        macDeviceID: String,
        record: MacPairedMacBackupRecordWire
    ) {
        self.macDeviceID = macDeviceID
        self.record = record
    }

    public let macDeviceID: String
    public let record: MacPairedMacBackupRecordWire
}
