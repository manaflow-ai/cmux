struct MacPairedMacBackupOpWire: Encodable {
    let macDeviceID: String
    let record: MacPairedMacBackupRecordWire
}
