import Foundation
@testable import CmuxNextRemoteView
import Testing

@Suite struct RemoteViewTabPolicyTests {
    private let policy = RemoteViewTabPolicy()

    @Test func onlyLoopbackHostsAreAcceptedIncludingReservedNames() {
        #expect(policy.isLoopback("mock"))
        #expect(policy.isLoopback("LOCALHOST"))
        #expect(policy.isLoopback("127.0.0.1"))
        #expect(policy.isLoopback("127.255.255.255"))
        #expect(!policy.isLoopback("127.0.0.01"))
        #expect(!policy.isLoopback("128.0.0.1"))
        #expect(!policy.isLoopback("localhost.example"))
    }

    @Test func remoteRecordsAndUnavailableBuildsNeverConnect() throws {
        let record = try #require(RemoteViewTabRecord(host: "local"))

        #expect(policy.decide(record: record, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
        #expect(policy.decide(record: record, source: .person, paneAvailable: false) == .unavailable(.notInThisBuild))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .connect(record))
    }

    @Test func invalidAndNonLoopbackRecordsExplainWhyTheyCannotOpen() throws {
        #expect(policy.decide(record: nil, source: .person, paneAvailable: true) == .unavailable(.invalidAddress))
        let record = try #require(RemoteViewTabRecord(host: "server-1"))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .unavailable(.notLoopback(host: "server-1")))
    }

    /// Open Desktop's native viewer: a Cloud machine's desktop record names only the machine and
    /// goes over the app's Cloud tunnel, so neither the loopback nor the private-network rule
    /// applies; a person's open connects, anything else asks first in view mode.
    @Test func aCloudDesktopRecordRoundTripsAndConnectsOnlyForAPerson() throws {
        let record = try #require(RemoteViewTabRecord(host: "vm-0dd1c008", target: .virtual, mode: .control, cloudDesktop: true))
        #expect(record.url.absoluteString == "cmux://remote-view?host=vm-0dd1c008&target=virtual&mode=control&via=cloud")
        #expect(RemoteViewTabRecord(url: record.url) == record)
        #expect(RemoteViewTabRecord(url: URL(string: "cmux://remote-view?host=vm-1&via=cloud&port=5901")) == nil, "a Cloud desktop names no port")
        #expect(RemoteViewTabRecord(host: "vm-1", vncPort: 5901, cloudDesktop: true) == nil)

        let rd = try #require(RemoteViewTabRecord(host: "vm-0dd1c008", target: .virtual, mode: .control, cloudDesktop: true, cloudRd: true))
        #expect(rd.url.absoluteString == "cmux://remote-view?host=vm-0dd1c008&target=virtual&mode=control&via=cloud-rd")
        #expect(RemoteViewTabRecord(url: rd.url) == rd)
        #expect(RemoteViewTabRecord(host: "vm-1", cloudRd: true) == nil, "cmux-rd is a Cloud desktop engine")
        #expect(policy.decide(record: rd, source: .person, paneAvailable: true) == .connect(rd))
        var rdView = rd
        rdView.mode = .view
        #expect(policy.decide(record: rd, source: .unconfirmed, paneAvailable: true) == .confirm(rdView), "an agent's open asks, view only")
        #expect(policy.decide(record: rd, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
        let hello = RemoteRdHello(user: "cmux", install: "test", token: String(repeating: "ab", count: 32))
        #expect(!String(describing: hello).contains("abab"), "a hello's description never shows its token")

        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .connect(record))
        var view = record
        view.mode = .view
        #expect(policy.decide(record: record, source: .unconfirmed, paneAvailable: true) == .confirm(view))
        #expect(policy.decide(record: record, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
    }

    /// A Cloud desktop's connecting card names the machine and its Cloud tunnel; the phase-1
    /// development note (loopback or a single-tenant overlay) is for the other paths only.
    @Test @MainActor func aCloudDesktopsConnectingCardHasNoDevelopmentNote() {
        let cloud = RemoteStateCard.spec(for: .connecting, host: "graceful-amber-owl", viaCloudTunnel: true)
        #expect(cloud.note == nil)
        #expect(cloud.title.contains("graceful-amber-owl"))
        #expect(cloud.detail == RemoteViewStrings.connectingCloudDetail)
        let other = RemoteStateCard.spec(for: .connecting, host: "local")
        #expect(other.note == RemoteViewStrings.developmentOnly)
    }

    /// A Cloud desktop that streamed and lost its path says "Reconnecting" while it connects
    /// again, and the next frame clears it; a first connect says "Connecting".
    @Test @MainActor func aLostCloudDesktopReadsReconnectingUntilItsNextFrame() {
        let reducer = RemotePaneReducer()
        var state = RemotePaneState(hostName: "graceful-amber-owl")
        state.viaCloudTunnel = true
        state = reducer.reduce(state, .status(RemoteViewStatus(path: .compatibility, state: .streaming)))
        state = reducer.reduce(state, .frameShown)
        #expect(state.hasFrame && !state.reconnecting)
        state = reducer.reduce(state, .status(RemoteViewStatus(path: .compatibility, state: .ended(.connectionLost))))
        state = reducer.reduce(state, .status(RemoteViewStatus(path: .compatibility, state: .connecting)))
        #expect(state.reconnecting)
        #expect(RemoteStateCard.spec(for: .connecting, host: "graceful-amber-owl", viaCloudTunnel: true, reconnecting: true).title
            == RemoteViewStrings.reconnectingTitle("graceful-amber-owl"))
        state = reducer.reduce(state, .status(RemoteViewStatus(path: .compatibility, state: .streaming)))
        state = reducer.reduce(state, .frameShown)
        #expect(!state.reconnecting, "the next frame clears it")
        #expect(RemoteStateCard.spec(for: .connecting, host: "graceful-amber-owl", viaCloudTunnel: true).title
            == RemoteViewStrings.connectingTitle("graceful-amber-owl"))
    }

    @Test func unconfirmedRecordsRequireConfirmationAndStartInViewMode() throws {
        let record = try #require(RemoteViewTabRecord(host: "local", mode: .control))
        let expected = try #require(RemoteViewTabRecord(host: "local", mode: .view))
        let decision = policy.decide(record: record, source: .unconfirmed, paneAvailable: true)

        #expect(decision == .confirm(expected))
    }
}
