import AppKit
@testable import CmuxNextDaemon
import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// cmux issue 36047: a Chief of this Mac can do computer use on one of the account's Cloud
/// machines. The card's Computer row offers This Mac and each Cloud machine, writes the pick as
/// engine.json's `computer` through the brain (`chief.engine.set`), and is not offered for a
/// Chief whose brain runs elsewhere.
@MainActor @Suite struct HomeChiefComputerPickTests {
    private static let machines = [HomeChiefCloudComputer(id: "vm-1", title: "Lab VM"),
                                   HomeChiefCloudComputer(id: "vm-2", title: "Browser box")]

    @Test func aLocalChiefAttachesACloudMachineAndDetachesIt() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: ComputerChief(writes: continuation))
        view.cloudComputers = { Self.machines }
        await view.refresh().value
        #expect(!view.computerRow.isHidden)
        #expect(view.computerPicker.titleOfSelectedItem == HomeEngineStrings.computerThisMac)
        #expect(view.computerDesktop.isHidden)
        let titles = view.computerPicker.itemArray.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [HomeEngineStrings.computerThisMac, "Lab VM", "Browser box", HomeEngineStrings.computerNew])
        var received = writes.makeAsyncIterator()

        let lab = try #require(view.computerPicker.itemArray.firstIndex { $0.title == "Lab VM" })
        view.computerPicker.selectItem(at: lab)
        view.pickedComputer(view.computerPicker)
        #expect(await received.next() == ["computer": "machine:vm-1"])

        // The brain's answer shows the attached machine, and Show Desktop opens its screen.
        await view.refresh().value
        #expect(view.computerPicker.titleOfSelectedItem == "Lab VM")
        #expect(!view.computerDesktop.isHidden)
        var opened: String?
        view.onShowComputerDesktop = { opened = $0 }
        view.showComputerDesktop()
        #expect(opened == "vm-1")

        let mac = try #require(view.computerPicker.itemArray.firstIndex { $0.title == HomeEngineStrings.computerThisMac })
        view.computerPicker.selectItem(at: mac)
        view.pickedComputer(view.computerPicker)
        #expect(await received.next() == ["computer": "none"])
    }

    @Test func newCloudComputerRunsTheCreateFlowAndWritesNothing() async throws {
        let (writes, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: ComputerChief(writes: continuation))
        view.cloudComputers = { Self.machines }
        var created = 0
        view.onNewCloudComputer = { created += 1 }
        await view.refresh().value
        let new = try #require(view.computerPicker.itemArray.firstIndex { $0.tag == HomeChiefSettingsView.newComputerTag })
        view.computerPicker.selectItem(at: new)
        view.pickedComputer(view.computerPicker)
        #expect(created == 1)
        // The picker goes back to what the Chief uses now; no engine write was sent.
        #expect(view.computerPicker.titleOfSelectedItem == HomeEngineStrings.computerThisMac)
        continuation.finish()
        var received = writes.makeAsyncIterator()
        #expect(await received.next() == nil)
    }

    @Test func aMachineTheListLostStaysShownByItsTarget() async {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let source = ComputerChief(writes: continuation)
        source.computer = "machine:gone"
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: source)
        view.cloudComputers = { Self.machines }
        await view.refresh().value
        #expect(view.computerPicker.titleOfSelectedItem == "machine:gone")
    }

    @Test func aChiefThatRunsElsewhereHasNoComputerRow() async {
        let (_, continuation) = AsyncStream.makeStream(of: [String: String?].self)
        let source = ComputerChief(writes: continuation)
        source.isLocal = false
        let view = HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: source)
        await view.refresh().value
        #expect(view.computerRow.isHidden)
    }

    /// The pick reaches the brain: `chief.engine.set` carries `computer`.
    @Test func theEngineSetSendsTheComputer() {
        let params = ChiefControlClient.engineSetParams(["computer": "machine:vm-1", "unknown": "x"], chief: nil)
        #expect(params["computer"] == .string("machine:vm-1"))
        #expect(params["unknown"] == nil)
    }
}

/// A brain that records each write and answers with the computer it last took.
private final class ComputerChief: HomeChiefEngineSource, @unchecked Sendable {
    let writes: AsyncStream<[String: String?]>.Continuation
    var isLocal = true
    var computer: String?
    var place: String? { nil }

    init(writes: AsyncStream<[String: String?]>.Continuation) {
        self.writes = writes
    }

    private var snapshot: HomeChiefSnapshot {
        var snapshot = HomeChiefSnapshot(harness: "claude", model: nil, effort: nil, avatar: nil, turns: [])
        snapshot.computer = computer
        return snapshot
    }

    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { snapshot }

    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        writes.yield(fields)
        if case let value?? = fields["computer"] { computer = value == "none" ? nil : value }
        return snapshot
    }
}
