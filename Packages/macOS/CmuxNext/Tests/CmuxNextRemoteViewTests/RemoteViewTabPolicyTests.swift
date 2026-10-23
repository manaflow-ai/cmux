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

    @Test func unconfirmedRecordsRequireConfirmationAndStartInViewMode() throws {
        let record = try #require(RemoteViewTabRecord(host: "local", mode: .control))
        let expected = try #require(RemoteViewTabRecord(host: "local", mode: .view))
        let decision = policy.decide(record: record, source: .unconfirmed, paneAvailable: true)

        #expect(decision == .confirm(expected))
    }
}
