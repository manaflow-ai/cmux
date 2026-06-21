@testable import CmuxMobileShell

/// In-memory backup double: records uploaded ops, counts fetches, and can be
/// told to fail the first N fetches to exercise the retry path.
actor FakeBackup: PairedMacBackingUp {
    private(set) var uploaded: [PairedMacBackupOp] = []
    private(set) var fetchCount = 0
    private let records: [PairedMacBackupRecord]
    private var failNextFetches: Int

    init(records: [PairedMacBackupRecord] = [], failNextFetches: Int = 0) {
        self.records = records
        self.failNextFetches = failNextFetches
    }

    func upload(ops: [PairedMacBackupOp]) async {
        uploaded.append(contentsOf: ops)
    }

    func fetchAll() async -> [PairedMacBackupRecord]? {
        fetchCount += 1
        if failNextFetches > 0 {
            failNextFetches -= 1
            return nil
        }
        return records
    }

    func uploadedOps() -> [PairedMacBackupOp] { uploaded }
    func fetches() -> Int { fetchCount }
}
