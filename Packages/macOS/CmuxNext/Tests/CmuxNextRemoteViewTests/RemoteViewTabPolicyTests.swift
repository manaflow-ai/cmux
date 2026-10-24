import Foundation
import CmuxNextRemoteView
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

        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .connect(record))
        var view = record
        view.mode = .view
        #expect(policy.decide(record: record, source: .unconfirmed, paneAvailable: true) == .confirm(view))
        #expect(policy.decide(record: record, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
    }

    @Test func unconfirmedRecordsRequireConfirmationAndStartInViewMode() throws {
        let record = try #require(RemoteViewTabRecord(host: "local", mode: .control))
        let expected = try #require(RemoteViewTabRecord(host: "local", mode: .view))
        let decision = policy.decide(record: record, source: .unconfirmed, paneAvailable: true)

        #expect(decision == .confirm(expected))
    }
}
