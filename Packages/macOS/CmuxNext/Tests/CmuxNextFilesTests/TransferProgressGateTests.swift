import Testing
@testable import CmuxNextFiles

/// copyfile reports every block it copies. The transfer sends the Files pane at most one update
/// per 1/200 of its bytes from inside a file, instead of one per block.
struct TransferProgressGateTests {
    @Test func aLargeCopysBlockReportsBecomeAboutTwoHundredUpdates() {
        var gate = TransferProgressGate(bytesTotal: 10_000_000_000)
        var sent = 0
        // 10 GB in 64 KB blocks: 152,588 copyfile reports.
        var done: Int64 = 0
        while done < 10_000_000_000 {
            done = min(10_000_000_000, done + 65_536)
            if gate.admits(done) { sent += 1 }
        }
        #expect(sent <= 201)
        #expect(sent >= 150)
    }

    // `admits` is mutating: #expect cannot call it on its own copy, so each result is read first.
    @Test func theFirstReportAlwaysGoesThrough() {
        var gate = TransferProgressGate(bytesTotal: 1_000_000)
        let first = gate.admits(10), tooSoon = gate.admits(20), next = gate.admits(10 + 5_000)
        #expect(first)
        #expect(!tooSoon)
        #expect(next)
    }

    @Test func aTinyTransferStillReports() {
        var gate = TransferProgressGate(bytesTotal: 0)
        #expect(gate.step == 1)
        let zero = gate.admits(0), one = gate.admits(1), again = gate.admits(1)
        #expect(zero)
        #expect(one)
        #expect(!again)
    }
}
