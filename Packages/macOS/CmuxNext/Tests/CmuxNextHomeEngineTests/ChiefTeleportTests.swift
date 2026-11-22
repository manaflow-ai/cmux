@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// Where the Chief runs now (chief-migration-DESIGN.md 7): the home's `state/moved.json` names the
/// target a move wrote (`local:<dir>`, `ssh:<host>:<dir>`, `cloud:<api>/<agent id>`, or a
/// `<host>:<dir>` a rollback's retire wrote on the far side); no file, or one the engine itself
/// would not read, is This Mac (the host starts there).
struct ChiefLocationTests {
    @Test(arguments: [
        (nil, ChiefLocation.thisMac),
        ("", .thisMac),
        ("local:/Users/me/.cmux/chief/other", .thisMac),
        ("cloud:https://api.cmux.dev/agent_123", .cloud),
        ("cloud", .cloud),
        ("cloud:staging", .cloud),
        ("ssh:cmux-mini:/Users/me/.cmux/chief/default", .host("cmux-mini")),
        ("ssh:lawrence@cmux-mini:~/.cmux/chief/default", .host("cmux-mini")),
        ("ssh:cmux-mini", .host("cmux-mini")),
        ("cmux-lawrences-mac-mini:/Users/me/.cmux/chief/default", .host("cmux-lawrences-mac-mini")),
    ] as [(String?, ChiefLocation)])
    func movedToNamesWhereTheChiefRuns(to: String?, expected: ChiefLocation) {
        #expect(ChiefLocation(movedTo: to) == expected)
    }

    @Test func movedJSONIsTheEnginesMarker() {
        let json = Data(#"{"to": "cloud:https://api.cmux.dev/agent_9", "at": "2026-11-03T10:00:00Z", "checkpoint_sha256": "ab"}"#.utf8)
        #expect(ChiefLocation(movedJSON: json) == .cloud)
        #expect(ChiefLocation(movedJSON: nil) == .thisMac)
        #expect(ChiefLocation(movedJSON: Data("not json".utf8)) == .thisMac, "the engine starts on a marker it cannot read")
        #expect(ChiefLocation(movedJSON: Data(#"{"at": "x"}"#.utf8)) == .thisMac)
    }

    @Test func theReaderReadsTheHomesMarkerOffTheMainThread() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-teleport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("state"), withIntermediateDirectories: true)
        let reader = ChiefLocationReader()
        #expect(await reader.read(home: home) == .thisMac)
        try Data(#"{"to": "ssh:me@cmux-mini:~/.cmux/chief/default", "at": "t", "checkpoint_sha256": ""}"#.utf8)
            .write(to: home.appendingPathComponent("state/moved.json"))
        #expect(await reader.read(home: home) == .host("cmux-mini"))
    }
}

/// The Teleport menu (the Home header's location chip and the Chief card's row): every place the
/// Chief can go, the one it is at checked and not pickable, the ones that cannot take it now greyed
/// out, and Roll Back only while the home is marked moved.
struct ChiefTeleportMenuTests {
    private let destinations: [ChiefTeleportDestination] = [
        .init(id: "local", title: "This Mac", place: .thisMac),
        .init(id: "ssh-mini", title: "Mac mini", place: .host("lawrence@cmux-mini")),
        .init(id: "ssh-gcp", title: "gcp-linux-1 (offline)", place: .host("gcp-linux-1"), isAvailable: false),
        .init(id: "cloud", title: "cmux Cloud", place: .cloud),
    ]

    private func state(_ menu: ChiefTeleportMenu, _ id: String) -> ChiefTeleportMenu.Row.State? {
        menu.rows.first { $0.id == id }?.state
    }

    @Test func onThisMacThisMacIsCheckedAndThereIsNothingToRollBack() {
        let menu = ChiefTeleportMenu(location: .thisMac, destinations: destinations, phase: .idle)
        #expect(menu.rows.map(\.id) == ["local", "ssh-mini", "ssh-gcp", "cloud"])
        #expect(state(menu, "local") == .current)
        #expect(state(menu, "ssh-mini") == .available)
        #expect(state(menu, "ssh-gcp") == .unavailable)
        #expect(state(menu, "cloud") == .available)
        #expect(menu.rollback == nil)
        #expect(menu.currentTitle == "This Mac")
    }

    @Test func inTheCloudThisMacBringsItBackAndRollBackShows() {
        let menu = ChiefTeleportMenu(location: .cloud, destinations: destinations, phase: .idle)
        #expect(state(menu, "local") == .available, "a move out of the cloud back to the original home")
        #expect(state(menu, "ssh-mini") == .available, "a move out of the cloud to a Mac mini")
        #expect(state(menu, "cloud") == .current)
        #expect(menu.rollback == .available)
        #expect(menu.currentTitle == "cmux Cloud")
    }

    @Test func onAMiniTheMiniIsCurrentWhateverUserTheDestinationNames() {
        let menu = ChiefTeleportMenu(location: .host("cmux-mini"), destinations: destinations, phase: .idle)
        #expect(state(menu, "ssh-mini") == .current)
        #expect(state(menu, "local") == .available)
        #expect(menu.currentTitle == "Mac mini", "the host shows by the name the person gave its group")
    }

    @Test func aHostNoLongerListedIsStillWhereItRuns() {
        let menu = ChiefTeleportMenu(location: .host("old-box"), destinations: destinations, phase: .idle)
        #expect(menu.rows.allSatisfy { $0.state != .current })
        #expect(menu.currentTitle == "old-box")
        #expect(menu.rollback == .available)
    }

    @Test(arguments: [ChiefTeleportPhase.checking("cmux Cloud"), .moving("cmux Cloud"), .verifying("cmux Cloud"), .rollingBack])
    func whileAMoveRunsNothingElseCanStart(phase: ChiefTeleportPhase) {
        let menu = ChiefTeleportMenu(location: .cloud, destinations: destinations, phase: phase)
        #expect(menu.rows.allSatisfy { $0.state == .current || $0.state == .busy })
        #expect(menu.rollback == .busy)
        #expect(phase.isRunning)
    }

    @Test(arguments: [ChiefTeleportPhase.idle, .done("cmux Cloud"), .failed("cmux Cloud", reason: "no route"), .rolledBack])
    func aFinishedMoveLeavesTheMenuOpen(phase: ChiefTeleportPhase) {
        let menu = ChiefTeleportMenu(location: .thisMac, destinations: destinations, phase: phase)
        #expect(state(menu, "cloud") == .available)
        #expect(!phase.isRunning)
    }
}
