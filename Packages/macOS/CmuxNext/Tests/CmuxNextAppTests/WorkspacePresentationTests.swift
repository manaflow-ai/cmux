import CmuxNextLayout
import Testing

/// `WorkspacePresentation.decide`, the one answer `showWorkspace(requested:)` performs and a person's
/// leave of a top page asks first: only `.workspace` shows panes, so the leave never trades a page
/// for a waiting view where the key would find no pane (lead 2026-11-04 on #35168).
@MainActor @Suite struct WorkspacePresentationTests {
    struct Facts {
        var creation = false, listed: Set<String> = ["a"], home: Set<String> = [], remote = false
        var waits = false, paused = false, awaited: Set<String> = [], members = ["a"]
    }

    static func decide(_ requested: String?, _ facts: Facts) -> WorkspacePresentation<String> {
        .decide(requested: requested, creation: facts.creation, workspace: { facts.listed.contains($0) ? $0 : nil },
                homeStands: { facts.home.contains($0) }, onRemoteMachine: facts.remote, machineWaits: { facts.waits },
                machinePaused: { facts.paused }, awaits: { facts.awaited.contains($0) },
                firstListed: { facts.members.first { facts.listed.contains($0) } })
    }

    static func name(_ presentation: WorkspacePresentation<String>) -> String {
        switch presentation {
        case .workspace(let id): "workspace \(id)"
        case .homePage(let id): "home \(id)"
        case .creation: "creation"
        case .waitingForMachine: "waiting"
        case .pausedMachine: "paused"
        case .awaitingWorkspace: "awaiting"
        case .nothing: "nothing"
        }
    }

    @Test func aListedRequestShowsItsPanes() {
        #expect(Self.name(Self.decide("a", Facts())) == "workspace a")
        #expect(Self.decide("a", Facts()).showsPanes)
    }

    @Test func aStaleRequestFallsBackToTheFirstListedWorkspace() {
        #expect(Self.name(Self.decide("gone", Facts())) == "workspace a")
        #expect(Self.name(Self.decide(nil, Facts())) == "workspace a")
    }

    @Test func aStaleRequestOnARemoteMachineThatWaitsOrIsPausedShowsNoPanes() {
        var waits = Facts(); waits.remote = true; waits.waits = true
        var paused = Facts(); paused.remote = true; paused.paused = true
        #expect(Self.name(Self.decide("gone", waits)) == "waiting")
        #expect(Self.name(Self.decide("gone", paused)) == "paused")
        #expect(!Self.decide("gone", waits).showsPanes && !Self.decide("gone", paused).showsPanes)
        // A local window never waits for a machine.
        var local = paused; local.remote = false
        #expect(Self.name(Self.decide("gone", local)) == "workspace a")
    }

    @Test func aRequestACreateStillAwaitsShowsNoPanes() {
        var facts = Facts(); facts.awaited = ["new"]
        #expect(Self.name(Self.decide("new", facts)) == "awaiting")
        #expect(!Self.decide("new", facts).showsPanes)
    }

    @Test func classicHomeACreationAndNothingShowNoPanes() {
        var home = Facts(); home.home = ["a"]
        #expect(Self.name(Self.decide("a", home)) == "home a")
        var creation = Facts(); creation.creation = true
        #expect(Self.name(Self.decide("a", creation)) == "creation")
        var empty = Facts(); empty.listed = []
        #expect(Self.name(Self.decide("gone", empty)) == "nothing")
        for presentation in [Self.decide("a", home), Self.decide("a", creation), Self.decide("gone", empty)] { #expect(!presentation.showsPanes) }
    }
}
