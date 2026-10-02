import AppKit
@testable import CmuxNextAgentActivity
import Foundation
import Testing

@MainActor
final class RecordingSource: AgentActivitySource {
    var sink: (@MainActor (AgentActivityUpdate) -> Void)?
    var follows: [(String, Bool)] = []
    var ops: [AgentActivityUserOp] = []

    func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void) { self.sink = sink }
    func follow(session: String, _ on: Bool) { follows.append((session, on)) }
    func image(for frame: AgentActivityFrameRef) async -> NSImage? { nil }
    func perform(_ op: AgentActivityUserOp) async throws { ops.append(op) }
}

@MainActor
struct AgentActivityModelTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func session(_ id: String, machine: String = AgentActivityModel.localMachine, status: AgentActivityStatus = .active,
                        last: TimeInterval = 0, label: String = "run", agent: String = "Claude Code",
                        apps: [String] = ["TextEdit"]) -> AgentActivitySession {
        AgentActivitySession(id: id, machine: machine, machineName: machine == AgentActivityModel.localMachine ? "This Mac" : machine,
                             label: label, agentKind: "claude", agentName: agent, attribution: .processTree,
                             workspaceTitle: "cmux", terminalTitle: "zsh", colorHex: "#E5484D", targetApps: apps,
                             status: status, startedAt: t0, lastActionAt: t0.addingTimeInterval(last))
    }

    static func frame(_ n: UInt64) -> AgentActivityFrameRef {
        AgentActivityFrameRef(blob: "b\(n)", width: 320, height: 200)
    }

    static func event(_ seq: UInt64, frame: Bool = true) -> AgentActivityEvent {
        AgentActivityEvent(seq: seq, time: t0.addingTimeInterval(Double(seq)), kind: .act, tool: "click",
                           afterFrame: frame ? Self.frame(seq) : nil)
    }

    func makeModel() -> (AgentActivityModel, RecordingSource) {
        let source = RecordingSource()
        let model = AgentActivityModel(source: source)
        model.start()
        return (model, source)
    }

    @Test func liveSessionsComeFirstThenNewestActivity() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [
            Self.session("ended-new", status: .ended(.agentEnd), last: 100),
            Self.session("live-old", last: 1),
            Self.session("live-new", last: 50),
            Self.session("paused", status: .paused, last: 10),
        ]))
        #expect(model.groups.first?.sessions.map(\.id) == ["live-new", "paused", "live-old", "ended-new"])
        #expect(model.liveLocalCount == 3)
    }

    @Test func thisMacIsListedBeforeOtherMachines() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: "aardvark-mini", [Self.session("m1", machine: "aardvark-mini")]))
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("l1")]))
        source.sink?(.connection(machine: "zz-vm", .unreachable))
        #expect(model.groups.map(\.id) == [AgentActivityModel.localMachine, "aardvark-mini", "zz-vm"])
        #expect(model.groups.last?.connection == .unreachable)
    }

    @Test func filterMatchesAgentLabelAppAndWorkspace() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [
            Self.session("a", label: "research", agent: "Codex", apps: ["Safari"]),
            Self.session("b", label: "figma-export", apps: ["Figma"]),
        ]))
        model.filter = "codex"
        #expect(model.groups.first?.sessions.map(\.id) == ["a"])
        model.filter = "FIGMA"
        #expect(model.groups.first?.sessions.map(\.id) == ["b"])
        model.filter = "  "
        #expect(model.groups.first?.sessions.count == 2)
    }

    @Test func selectionFollowsTheHostAndAsksForEvents() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a", last: 1), Self.session("b", last: 2)]))
        #expect(model.selectedSessionID == "b")
        model.select(session: "a")
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a", last: 9), Self.session("b", last: 2)]))
        #expect(model.selectedSessionID == "a", "an update keeps the user's selection")
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("b", last: 2)]))
        #expect(model.selectedSessionID == "b", "a removed session falls back to the first one")
        #expect(source.follows.map(\.0) == ["b", "b", "a", "a", "b"])
        #expect(source.follows.map(\.1) == [true, false, true, false, true])
    }

    @Test func eventsAppendInOrderAndIgnoreDuplicates() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a")]))
        source.sink?(.events(session: "a", [Self.event(0), Self.event(1)]))
        source.sink?(.events(session: "a", [Self.event(1), Self.event(2)]))
        #expect(model.selectedEvents.map(\.seq) == [0, 1, 2])
    }

    @Test func scrubbingStepsEventsAndFramesAndFollowsNewest() {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a")]))
        source.sink?(.events(session: "a", [Self.event(0), Self.event(1, frame: false), Self.event(2), Self.event(3, frame: false)]))
        #expect(model.isFollowingNewest)
        #expect(model.currentEvent?.seq == 3)
        #expect(model.currentFrameEvent?.seq == 2, "an event without pixels shows the last earlier frame")
        model.step(-1)
        #expect(model.currentEvent?.seq == 2)
        model.step(-1, framesOnly: true)
        #expect(model.currentEvent?.seq == 0)
        model.step(-5)
        #expect(model.currentEvent?.seq == 0)
        model.step(1, framesOnly: true)
        #expect(model.currentEvent?.seq == 2)
        // a new event does not move a scrubbed position
        source.sink?(.events(session: "a", [Self.event(4)]))
        #expect(model.currentEvent?.seq == 2)
        model.scrubToEnd()
        #expect(model.isFollowingNewest)
        #expect(model.currentEvent?.seq == 4)
        model.scrubToStart()
        #expect(model.currentEvent?.seq == 0)
    }

    @Test func stopIsSentToTheHostWithoutChangingTheSessionLocally() async {
        let (model, source) = makeModel()
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a")]))
        model.perform(.stop(session: "a"))
        while source.ops.isEmpty { await Task.yield() }
        #expect(source.ops == [.stop(session: "a")])
        #expect(model.selectedSession?.status == .active, "no optimistic change: the host's update decides")
        source.sink?(.sessions(machine: AgentActivityModel.localMachine, [Self.session("a", status: .ended(.userStop))]))
        #expect(model.selectedSession?.status == .ended(.userStop))
        #expect(model.liveLocalCount == 0)
    }
}
