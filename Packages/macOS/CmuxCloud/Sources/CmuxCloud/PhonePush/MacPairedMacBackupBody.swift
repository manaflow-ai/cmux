public struct MacPairedMacBackupBody: Encodable, Sendable {
    public init(
        ops: [MacPairedMacBackupOpWire]
    ) {
        self.ops = ops
    }

    public let ops: [MacPairedMacBackupOpWire]
}
