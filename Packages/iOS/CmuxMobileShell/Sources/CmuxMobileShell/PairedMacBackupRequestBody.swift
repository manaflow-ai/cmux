struct PairedMacBackupRequestBody: Encodable {
    let ops: [PairedMacBackupOpWire]
    let expectedRevision: Int?

    init(
        ops: [PairedMacBackupOpWire],
        expectedRevision: Int? = nil
    ) {
        self.ops = ops
        self.expectedRevision = expectedRevision
    }
}
