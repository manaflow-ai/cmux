import AppKit
@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// The Chief's computer lives in the Chief Settings card the name pill opens, under who the Chief
/// is, as Messages shows Find My on a contact's card (cmux issue 31488); no header toggle opens it.
@MainActor @Suite(.serialized) struct HomeChiefSettingsComputerTests {
    @Test func theComputerSitsUnderTheIdentityWithItsHeader() async {
        let view = Self.card()
        var statuses = 0
        view.computer.source = .init(paid: { true }, chief: { "Ada" },
                                     status: { statuses += 1; return .init(used: true, computer: ("vm", "suspended")) },
                                     screen: { nil })
        let rows = view.stack.arrangedSubviews
        let header = rows.firstIndex { $0 === view.computerHeader }
        let section = rows.firstIndex { $0 === view.computer }
        let agent = rows.firstIndex { ($0 as? NSTextField)?.stringValue == HomeEngineStrings.agentSection }
        #expect(header != nil && section == header.map { $0 + 1 })
        #expect(section.flatMap { s in agent.map { s < $0 } } == true, "the computer comes before the Agent settings")
        #expect(view.computerHeader.isHidden && view.computer.isHidden, "nothing shows before the first read")
        view.computer.open()
        await until { view.computer.shown != nil }
        #expect(!view.computerHeader.isHidden)
        #expect((view.computerHeader as? NSTextField)?.stringValue == HomeEngineStrings.computerSection)
        view.cardClosed()
        #expect(!view.computer.isOpen, "closing the card stops the reads")
        #expect(statuses >= 1)
    }

    @Test func aChiefWithoutAComputerShowsNoSection() async {
        let view = Self.card()
        var statuses = 0
        view.computer.source = .init(paid: { true }, chief: { "Ada" },
                                     status: { statuses += 1; return .init(used: false, computer: nil) },
                                     screen: { nil })
        view.computer.open()
        await until { statuses >= 1 }
        for _ in 0..<50 { await Task.yield() }
        #expect(view.computer.isHidden && view.computerHeader.isHidden)
        view.cardClosed()
    }

    private static func card() -> HomeChiefSettingsView {
        let home = FileManager.default.temporaryDirectory
        return HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
    }

    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}
