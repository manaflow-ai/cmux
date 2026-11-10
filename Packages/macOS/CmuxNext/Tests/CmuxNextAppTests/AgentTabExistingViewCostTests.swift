import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Leo's NIGHTLY hung the main thread 3.2 s and 4.6 s (hang files 2026-11-09 13:19 and 14:23) in one
/// workspace hibernation pass: `hibernationResidents` asks `holdsTabMemory` for every tab of every
/// workspace, and each ask resolved the key through `tabKey`, which reads every listed chat tab of every
/// machine (`listTabsScoped`) when no made page answers to the key, as for every terminal and browser
/// tab. A pass so cost tabs times listed chats. Asking for a tab no page answers to now reads none.
@MainActor @Suite(.serialized)
struct AgentTabExistingViewCostTests {
    static let thisMac = "install:existing-view-cost-test"

    final class Reads { var count = 0 }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    static func store(listed: [String], reads: Reads) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = thisMac
        let records = Dictionary(uniqueKeysWithValues: listed.map {
            ($0, AgentSessionRef(host: thisMac, hostName: "This Mac", session: "s-\($0)", harness: "claude"))
        })
        tabs.listTabsScoped = {
            reads.count += 1
            return records.map { (key: $0.key, record: $0.value, machine: thisMac) }
        }
        return tabs
    }

    @Test func askingForTabsNoPageAnswersToReadsNoListedTabs() {
        let reads = Reads()
        let tabs = Self.store(listed: (0..<200).map { "tab_chat_\($0)" }, reads: reads)
        for index in 0..<500 { #expect(tabs.existingView("term_\(index)") == nil) }
        #expect(reads.count == 0, "each ask read every listed chat tab: \(reads.count) reads for 500 asks")
    }

    @Test func aMadePageStillAnswersToItsKeyAndItsAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "existing-view-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "index.html")
        try Data("<html><body></body></html>".utf8).write(to: file)
        let reads = Reads()
        let tabs = Self.store(listed: ["tab_chat", "tab_new"], reads: reads)
        let page = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost()), source: .bundled(file)))
        defer { page.close() }
        tabs.views[AgentTabKey(machine: Self.thisMac, key: "tab_chat")] = page
        #expect(tabs.existingView("tab_chat") === page)
        // A provisional tab id resolves to the chat's tab through its alias.
        tabs.aliases[AgentTabKey(machine: Self.thisMac, key: "tab_new")] = "tab_chat"
        #expect(tabs.existingView("tab_new") === page)
        #expect(tabs.existingView("term_1") == nil)
    }
}
