import AppKit
import CmuxNextTerminalFind
import Testing
@testable import CmuxNextTerminal

/// R81: a new terminal does not build its find bar (about 5 ms of main
/// thread, most of a 120 Hz frame); the bar is built the first time find opens.
@MainActor
@Suite struct TerminalFindBarLazyTests {
    static func bars(in host: TerminalHostView) -> Int { host.subviews.filter { $0 is TerminalFindBarView }.count }

    @Test func aNewTerminalHasNoFindBarUntilFindOpens() async {
        let host = TerminalHostView()
        let find = TerminalFindController()
        host.attachFind(find)
        #expect(Self.bars(in: host) == 0)
        find.open(takeFocus: false)
        // The bar follows the open on the next main-actor turn.
        for _ in 0..<20 where Self.bars(in: host) == 0 { await Task.yield() }
        #expect(Self.bars(in: host) == 1)
    }

    @Test func findAlreadyOpenGetsItsBarAtOnce() {
        let host = TerminalHostView()
        let find = TerminalFindController()
        find.open(takeFocus: false)
        host.attachFind(find)
        #expect(Self.bars(in: host) == 1)
    }
}
