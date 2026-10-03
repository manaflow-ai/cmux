import Foundation
import Testing
@testable import CmuxNextRemoteView

/// plans/cmux-next/remote-desktop.md 11.0: what a `remote_view` tab may do
/// in phase 1, checked for both build kinds through `paneAvailable`.
struct RemoteViewTabPolicyTests {
    private func record(_ host: String, mode: RemoteControlMode = .control) -> RemoteViewTabRecord {
        RemoteViewTabRecord(host: host, target: .display(1), mode: mode)!
    }

    @Test(arguments: [true, false])
    func remoteTreeRecordsAreRefusedInEveryBuild(paneAvailable: Bool) {
        for host in ["mock", "localhost", "127.0.0.1", "build-mini"] {
            for source in [RemoteViewTabSource.remoteTree] {
                #expect(RemoteViewTabPolicy.decide(record: record(host), source: source, paneAvailable: paneAvailable)
                        == .unavailable(.remoteRecord))
            }
        }
        #expect(RemoteViewTabPolicy.decide(record: nil, source: .remoteTree, paneAvailable: paneAvailable) == .unavailable(.remoteRecord))
    }

    @Test(arguments: [true, false])
    func automationNeverConnectsByItselfInEveryBuild(paneAvailable: Bool) {
        for host in ["mock", "local", "localhost", "127.0.0.1", "127.255.0.9", "build-mini", "10.0.0.2"] {
            let decision = RemoteViewTabPolicy.decide(record: record(host), source: .unconfirmed, paneAvailable: paneAvailable)
            if case .connect = decision { Issue.record("unconfirmed \(host) connected") }
        }
    }

    @Test func buildsWithoutThePaneShowNotAvailable() {
        for source in [RemoteViewTabSource.person, .unconfirmed] {
            #expect(RemoteViewTabPolicy.decide(record: record("localhost"), source: source, paneAvailable: false)
                    == .unavailable(.notInThisBuild))
        }
    }

    @Test func developmentBuildsConnectOnlyToLoopback() {
        for host in ["mock", "MOCK", "local", "localhost", "127.0.0.1", "127.1.2.3"] {
            let r = record(host)
            #expect(RemoteViewTabPolicy.decide(record: r, source: .person, paneAvailable: true) == .connect(r), "\(host)")
            var view = r
            view.mode = .view
            #expect(RemoteViewTabPolicy.decide(record: r, source: .unconfirmed, paneAvailable: true) == .confirm(view), "\(host)")
        }
        for host in ["build-mini", "mac_01", "10.0.0.2", "128.0.0.1", "localhost.example.com", "127.0.0.1.nip.io",
                     "127.0.0", "127.0.0.256", "127.00.0.1", "0177.0.0.1", "local-host"] {
            #expect(RemoteViewTabPolicy.decide(record: record(host), source: .person, paneAvailable: true)
                    == .unavailable(.notLoopback(host: host)), "\(host)")
        }
    }

    @Test func invalidAddressesNeverConnect() {
        #expect(RemoteViewTabPolicy.decide(record: nil, source: .person, paneAvailable: true) == .unavailable(.invalidAddress))
        #expect(RemoteViewTabPolicy.decide(record: nil, source: .unconfirmed, paneAvailable: true) == .unavailable(.invalidAddress))
    }

    @Test func everyReasonHasText() {
        let reasons: [RemoteViewUnavailableReason] = [.notInThisBuild, .noTransport(host: "h"), .notLoopback(host: "h"), .remoteRecord, .invalidAddress]
        for reason in reasons {
            let text = RemoteViewUnavailableView.text(for: .unavailable(reason))
            #expect(!text.title.isEmpty && !text.detail.isEmpty)
        }
        #expect(RemoteViewUnavailableView.text(for: .confirm(host: "mock")).title.contains("mock"))
    }
}
