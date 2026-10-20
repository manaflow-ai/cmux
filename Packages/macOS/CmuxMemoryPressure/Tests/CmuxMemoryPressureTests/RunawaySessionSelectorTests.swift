import Testing

@testable import CmuxMemoryPressure

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/22273:
/// one terminal's runaway `next dev` session must be selectable without
/// touching its login or shell, or anything outside its tty.
@Suite("Runaway session selection")
struct RunawaySessionSelectorTests {
    private static let gb: Int64 = 1024 * 1024 * 1024
    private static let tty: Int64 = 0x1600_0003
    private static let appPID = 50

    private let selector = RunawaySessionSelector(
        appProcessID: Self.appPID,
        appProcessGroupID: Self.appPID,
        thresholdBytes: 8 * Self.gb
    )

    private func process(
        _ pid: Int,
        parent: Int,
        name: String = "node",
        group: Int,
        bytes: Int64,
        tty: Int64? = Self.tty
    ) -> RunawaySessionProcess {
        RunawaySessionProcess(
            pid: pid, parentPID: parent, name: name,
            processGroupID: group, ttyDevice: tty, memoryBytes: bytes
        )
    }

    /// app(50) -> login(100) -> zsh(200).
    private func session(loginParent: Int = Self.appPID) -> [RunawaySessionProcess] {
        [
            process(100, parent: loginParent, name: "login", group: 100, bytes: 4_000_000),
            process(200, parent: 100, name: "zsh", group: 200, bytes: 8_000_000),
        ]
    }

    /// `next dev`(300) and 60 node workers in job group 300 (31 GB total).
    private func runawayJob(
        workerCount: Int = 60,
        includeLeader: Bool = true,
        workerParent: Int = 300,
        group: Int = 300
    ) -> [RunawaySessionProcess] {
        var processes: [RunawaySessionProcess] = []
        if includeLeader {
            processes.append(process(300, parent: 200, group: group, bytes: Self.gb))
        }
        for index in 0..<workerCount {
            processes.append(process(1_000 + index, parent: workerParent, group: group, bytes: Self.gb / 2))
        }
        return processes
    }

    private func select(
        _ processes: [RunawaySessionProcess],
        aggregateGB: Int64 = 32
    ) -> RunawaySessionSelection? {
        selector.selection(
            ttyDevice: Self.tty,
            in: RunawaySessionCensus(processes: processes),
            aggregateBytes: UInt64(aggregateGB * Self.gb)
        )
    }

    @Test("selects only the runaway job group, never login or the shell")
    func selectsOnlyTheRunawayJobGroup() {
        let selection = select(session() + runawayJob())

        #expect(selection?.processGroupIDs == [300])
        #expect(selection?.processCount == 61)
        #expect(selection?.memoryBytes == 31 * Self.gb + 12_000_000)
    }

    @Test("workers reparented to launchd keep their group selectable")
    func orphanedWorkersStaySelectable() {
        let selection = select(session() + runawayJob(includeLeader: false, workerParent: 1))

        #expect(selection?.processGroupIDs == [300])
    }

    @Test("detached apps outside the tty are never measured or signalled")
    func detachedAppsAreIgnored() {
        let detached = [
            process(700, parent: 1, name: "Code", group: 700, bytes: 20 * Self.gb, tty: nil),
            process(701, parent: 700, name: "zsh", group: 701, bytes: 20 * Self.gb, tty: 0x1600_0099),
        ]

        #expect(select(session() + detached) == nil)
        let selection = select(session() + runawayJob() + detached, aggregateGB: 60)
        #expect(selection?.processGroupIDs == [300])
        #expect(selection?.processCount == 61)
    }

    @Test("a group with a member off the tty is never signalled")
    func groupLeavingTheTTYIsIgnored() {
        let escaped = process(900, parent: 1, group: 300, bytes: 0, tty: nil)

        #expect(select(session() + runawayJob() + [escaped]) == nil)
    }

    @Test("a session without its app-spawned root fails closed")
    func missingSessionRootFailsClosed() {
        #expect(select(session(loginParent: 1) + runawayJob()) == nil)
    }

    /// A small suspended job (`vim`, group 400) that releases nothing.
    private func bystander() -> [RunawaySessionProcess] {
        [process(400, parent: 200, name: "vim", group: 400, bytes: 50_000_000)]
    }

    @Test("a command sharing the shell's group is never signalled, nor are bystanders")
    func shellGroupIsProtected() {
        let runawayInShellGroup = runawayJob(includeLeader: false, workerParent: 200, group: 200)

        #expect(select(session() + runawayInShellGroup) == nil)
        #expect(select(session() + runawayInShellGroup + bystander()) == nil)
    }

    @Test("bystander jobs are untouched when the runaway group can't be signalled")
    func bystandersSurviveAnUnsignallableRunaway() {
        let escaped = process(900, parent: 1, group: 300, bytes: 0, tty: nil)

        #expect(select(session() + runawayJob() + [escaped] + bystander()) == nil)
    }

    @Test("only the runaway group is picked when a bystander job shares the tty")
    func bystanderIsNotPickedWithTheRunaway() {
        #expect(select(session() + runawayJob() + bystander())?.processGroupIDs == [300])
    }

    @Test("the app's own group is never signalled")
    func appGroupIsProtected() {
        #expect(select(session() + runawayJob(group: Self.appPID)) == nil)
    }

    @Test("below the threshold nothing is selected")
    func belowThreshold() {
        #expect(select(session() + runawayJob(workerCount: 4), aggregateGB: 4) == nil)
    }

    @Test("a session that does not dominate the aggregate is not selected")
    func notDominant() {
        #expect(select(session() + runawayJob(), aggregateGB: 80) == nil)
    }

    @Test("groups are released largest first until below the clear level")
    func releasesLargestGroupsFirst() {
        let small = (0..<4).map { process(2_000 + $0, parent: 200, group: 400, bytes: Self.gb / 4) }
        let selection = select(session() + runawayJob() + small)

        #expect(selection?.processGroupIDs == [300])
    }
}
