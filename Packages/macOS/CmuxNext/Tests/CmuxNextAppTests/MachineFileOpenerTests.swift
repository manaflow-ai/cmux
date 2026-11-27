@testable import CmuxNextServer
import Testing

/// `cmux file open --machine M --path P` (own-machine parity's file step) finds `M` among the connected
/// machines first, then the Macs joined by sign-in; a joined Mac with an open session is reached through it,
/// one without is dialed first, and with no pane of it shown a new workspace gives one.
/// Leo: "Own machines as good as Cloud".
@MainActor struct MachineFileOpenerTests {
    private typealias Opener = MachineFileOpener<String>
    private static let studio = JoinedMachine(id: "machine_s1", name: "Studio", state: .online, platform: "macos", hostname: "studio.local")
    private let connected: [(id: String, name: String?)] = [(id: "srv-1", name: "builder"), (id: "cloud-9", name: "Cloud Box")]

    @Test func aConnectedMachineIsFoundByIdOrNameInAnyCase() {
        #expect(Opener.reach("srv-1", connected: connected, joined: [Self.studio], joinedByMachine: [:]) == .connected("srv-1"))
        #expect(Opener.reach("cloud box", connected: connected, joined: [Self.studio], joinedByMachine: [:]) == .connected("cloud-9"))
    }

    @Test func aJoinedMacIsFoundByIdRowIdNameOrHostname() {
        for name in ["machine_s1", "joined:machine_s1", "studio", "STUDIO.local", " Studio "] {
            #expect(Opener.reach(name, connected: connected, joined: [Self.studio], joinedByMachine: [:]) == .joined(Self.studio), "\(name)")
        }
    }

    @Test func aJoinedMacWithAnOpenSessionUsesIt() {
        let open = connected + [(id: "signed-in-7", name: nil)]
        #expect(Opener.reach("joined:machine_s1", connected: open, joined: [Self.studio], joinedByMachine: ["signed-in-7": "machine_s1"])
            == .connected("signed-in-7"))
    }

    @Test func anUnknownOrEmptyNameIsUnknown() {
        #expect(Opener.reach("nowhere", connected: connected, joined: [Self.studio], joinedByMachine: [:]) == .unknown)
        #expect(Opener.reach("", connected: connected, joined: [Self.studio], joinedByMachine: [:]) == .unknown)
    }

    @Test func aShownPaneOfAConnectedMachineOpensWithNoDial() async {
        var dials = 0
        let opener = Opener(connected: { [(id: "srv-1", name: "builder")] }, joined: { ([Self.studio], [:]) }, refreshJoined: {},
                            dial: { _ in dials += 1; return .opened }, shownPane: { $0 == "srv-1" ? "pane-a" : nil },
                            newWorkspace: { _ in Issue.record("no workspace"); return false })
        #expect(await opener.pane(machine: "builder") == .success("pane-a"))
        #expect(dials == 0)
    }

    @Test func aJoinedMacIsDialedThenGetsANewWorkspacesPane() async {
        var byMachine: [String: String] = [:], made: [String] = []
        let opener = Opener(connected: { [] }, joined: { ([Self.studio], byMachine) }, refreshJoined: {},
                            dial: { _ in byMachine["signed-in-7"] = "machine_s1"; return .opened },
                            shownPane: { made.contains($0) ? "pane-new" : nil }, newWorkspace: { made.append($0); return true })
        #expect(await opener.pane(machine: "Studio") == .success("pane-new"))
        #expect(made == ["signed-in-7"])
    }

    @Test func refusalsNameTheMachine() async {
        var refreshed = 0
        let unknown = Opener(connected: { [] }, joined: { ([], [:]) }, refreshJoined: { refreshed += 1 }, dial: { _ in .opened },
                             shownPane: { _ in nil }, newWorkspace: { _ in false })
        #expect(await unknown.pane(machine: "nowhere") == .failure(.noMachine("nowhere")))
        #expect(refreshed == 1, "an unknown name reads the joined list once")
        let asking = Opener(connected: { [] }, joined: { ([Self.studio], [:]) }, refreshJoined: {}, dial: { _ in .consentRequired },
                            shownPane: { _ in nil }, newWorkspace: { _ in false })
        #expect(await asking.pane(machine: "Studio") == .failure(.consent("Studio")))
        #expect(MachineFileOpenRefusal(answer: .unavailable("route.connect"), name: "Studio") == .unreachable("Studio"))
        #expect(MachineFileOpenRefusal.noPane.message == nil)
        #expect(MachineFileOpenRefusal.noMachine("x").message?.contains("x") == true)
    }
}
