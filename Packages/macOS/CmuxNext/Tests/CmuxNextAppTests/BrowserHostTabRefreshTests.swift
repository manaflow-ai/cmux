import AppKit
import CmuxNextBrowser
@testable import CmuxNextBrowserHost
import Foundation
import Testing

/// A tab or workspace switch tells the browser host provider which tabs it showed or hid
/// (`refreshTabs(changed:)`). With no host linked, nothing reads the tab list: every switch walked
/// every browser tab of the session (each tab's page, profile and extension access) on its own turn.
@MainActor @Suite(.serialized) struct BrowserHostTabRefreshTests {
    /// Counts the reads of the whole list and of single tabs.
    final class Source: ProviderTabSource, ProviderAccessSource {
        var listReads = 0
        var tabReads = 0
        var tabs: [ProviderTab] = (0..<100).map { index in
            ProviderTab(targetID: "tab-\(index)", engine: .cef, workspace: "ws", profile: "p", url: "https://example.com/\(index)",
                        title: "t\(index)", visible: index == 0)
        }
        var providerTabs: [ProviderTab] { listReads += 1; return tabs }
        func providerTab(_ targetID: String) -> ProviderTab? { tabReads += 1; return tabs.first { $0.targetID == targetID } }
        func access(forTab targetID: String) -> ProviderTabAccess { ProviderTabAccess(extensionHostAccess: false, userOverride: false, extensions: []) }
    }

    final class Credentials: ProviderCredentialsSource {
        func providerCredentials() async -> ProviderCredentials? { nil }
    }

    final class Relay: ProviderDevToolsRelay, ProviderAgentMarking {
        func prepareRelay(targetID: String) async -> Bool { false }
        func startRelay(targetID: String, onMessage: @escaping (String) -> Void, onEnd: @escaping () -> Void) -> Bool { false }
        func send(targetID: String, message: String) -> CEFDevToolsRawSend { .noBrowser }
        func stopRelay(targetID: String) {}
        func agentWillDrive(targetID: String) {}
    }

    @Test func switchesWithNoHostLinkedReadNoTab() throws {
        let source = Source(), relay = Relay()
        let provider = BrowserHostProvider(identity: ProviderIdentity(providerID: "test", installID: "test"), credentials: Credentials(),
                                           tabs: source, access: source, driver: nil, relay: relay, marking: relay)
        provider.start()
        provider.stop()
        let before = (source.listReads, source.tabReads)
        for index in 0..<50 {
            provider.refreshTabs(changed: ["tab-\(index)", "tab-\(index + 1)"])
            provider.refreshTabs()
        }
        #expect(source.listReads == before.0, "\(source.listReads - before.0) reads of every tab for 100 refreshes with no host linked")
        #expect(source.tabReads == before.1)
    }
}
