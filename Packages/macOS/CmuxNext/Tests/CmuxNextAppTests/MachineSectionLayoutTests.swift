@testable import CmuxNextServer
import Foundation
import Testing

/// The Machines rows as the app reads them (the hosts sidebar draws them).
@Suite struct MachineSectionLayoutTests {
    @Test func aRowsKindAndStateFollowItsLink() {
        #expect(MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true).kind == .local)
        #expect(MachineSectionRow(id: "x", name: "x", isConnected: false, isLocal: false).kind == .ssh)
        let connecting = MachineSectionRow(id: "c", name: "c", isConnected: false, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(connecting.isConnecting)
        // A connected link is never "connecting", whatever the caller passed.
        let connected = MachineSectionRow(id: "c", name: "c", isConnected: true, isLocal: false, kind: .cloud, isConnecting: true)
        #expect(!connected.isConnecting)
    }

    /// A paused Cloud machine is not connecting (cloud dogfood: three paused machines spun forever): its
    /// row has no spinner even while its daemon retries the link. A resume keeps one; a failed or
    /// deleted machine has none; a connected link wins.
    @Test func aCloudMachinesServerStateReplacesTheConnectingSpinner() {
        func row(_ state: MachineServerState?, connected: Bool = false, connecting: Bool = true) -> MachineSectionRow {
            MachineSectionRow(id: "c", name: "c", isConnected: connected, isLocal: false, kind: .cloud, isConnecting: connecting,
                              serverState: state)
        }
        #expect(!row(.paused).isConnecting && row(.paused).serverState == .paused)
        #expect(row(.resuming, connecting: false).isConnecting)
        #expect(!row(.failed).isConnecting && !row(.deleted).isConnecting)
        let connected = row(.paused, connected: true)
        #expect(connected.serverState == nil && !connected.isConnecting)
        #expect(row(nil).isConnecting)
    }

    @Test func theFixtureHasEveryRemoteKindAndState() {
        let fixture = MachineSectionRow.fixtures
        #expect(Set(fixture.map(\.kind)) == [.cloud, .ssh, .server])
        #expect(fixture.contains { $0.isConnecting })
        #expect(fixture.contains { !$0.isConnected && !$0.isConnecting })
        #expect(fixture.contains { $0.serverState == .paused && !$0.isConnecting })
        #expect(Set(fixture.map(\.id)).count == fixture.count)
        #expect(!fixture.contains { $0.isLocal })
    }

    /// acpmux's probe refusals as the app reads them, and the route of a joined Mac among acpmux's.
    @Test func aProbeRefusalAndARouteReadAsTheAppNeedsThem() {
        #expect(JoinedDialAnswer(refusal: "consent_required") == .consentRequired)
        #expect(JoinedDialAnswer(refusal: "consent_declined") == .consentDeclined)
        #expect(JoinedDialAnswer(refusal: "service.unknown").json == ["state": "unavailable", "reason": "service.unknown"])
        #expect(JoinedDialAnswer(refusal: nil) == .unavailable("machine.unreachable"))
        // Only a Mac answers the ask; a Linux box that still asks reads as one to update.
        #expect(JoinedDialAnswer(refusal: "consent_required", platform: "macOS") == .consentRequired)
        #expect(JoinedDialAnswer(refusal: "consent_required", platform: "linux") == .unavailable(JoinedDialAnswer.outdated))
        #expect(JoinedDialAnswer(refusal: "consent_declined", platform: "linux") == .consentDeclined)
        let routes: [[String: Any]] = [["daemonId": "k1", "host": "studio-mini"], ["daemonId": "k2", "host": "Air"],
                                       ["daemonId": "k3", "host": "twin"], ["daemonId": "k4", "host": "twin"]]
        let byPeer = JoinedMachine(id: "m", name: "x", state: .online, meshPeerId: "k2")
        #expect(byPeer.route(in: routes)?["daemonId"] as? String == "k2")
        #expect(JoinedMachine(id: "m", name: "studio-mini", state: .online, meshPeerId: "gone").route(in: routes) == nil)
        let byName = JoinedMachine(id: "m", name: "Studio-Mini", state: .online)
        #expect(byName.route(in: routes)?["daemonId"] as? String == "k1")
        #expect(JoinedMachine(id: "m", name: "twin", state: .online).route(in: routes) == nil)
        #expect(JoinedMachine(id: "m", name: "x", state: .online, platform: "macOS").isMac)
        #expect(!JoinedMachine(id: "m", name: "x", state: .online, platform: "linux").isMac)
        #expect(JoinedMachine(id: "m", name: "x", state: .online, platform: "linux").opensOverHub)
        #expect(!JoinedMachine(id: "m", name: "x", state: .offline, platform: "macos").opensOverHub)
        #expect(!JoinedMachine(id: "m", name: "x", state: .revoked, platform: "linux").opensOverHub)
    }
}
