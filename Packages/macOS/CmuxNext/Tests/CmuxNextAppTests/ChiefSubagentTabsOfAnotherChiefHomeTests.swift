import CmuxNextActions
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
import CmuxNextWakeups

/// #25262 (cmux NEXT nightly 4023940374302): a Chief subagent's chat tab said "This chat belongs
/// to another machine, so it does not run here", and Retry never helped. Its record names the
/// Chief home it was made under (`chief:01c91c5e`, NIGHTLY's per-build home
/// `~/.cmux/chief/com.cmuxterm.app.nightly.cmux-next` before NIGHTLY moved to the shared
/// `default` home), not the app's current one (`chief:b902d10e`), so the tab was taken for
/// another machine's. Every `chief:<home id>` a tab of this Mac's tree names is a Chief home of
/// this Mac: its chat opens from that home's acpmux, or from this Mac's when it runs there.
@MainActor struct ChiefSubagentTabsOfAnotherChiefHomeTests {
    private func reached(_ host: (any AgentPaneHostProviding)?, session: String) async -> String? {
        guard let host else { return nil }
        do {
            _ = try await host.handshake(sessionId: session)
            return nil
        } catch let reached as ChiefSubagentReached {
            return reached.host
        } catch {
            return nil
        }
    }

    private let local = "install:3f2a"
    private let kept = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc"

    /// `<base>/default` (the app's Chief home) and `<base>/com.cmuxterm.app.nightly.cmux-next`
    /// (the old one), whose own acpmux keeps the subagent's chat on disk (its daemon has ended).
    private func homes() throws -> (base: URL, current: ChiefHome, old: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-other-home-\(UUID().uuidString)/chief", isDirectory: true)
        let current = ChiefHome(root: base.appendingPathComponent("default", isDirectory: true), isolated: false,
                                buildID: ChiefHome.nightlyBundleID)
        let old = base.appendingPathComponent("com.cmuxterm.app.nightly.cmux-next", isDirectory: true)
        try FileManager.default.createDirectory(at: current.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old.appendingPathComponent("acpmux/sessions/\(kept)", isDirectory: true),
                                                withIntermediateDirectories: true)
        return (base, current, old)
    }

    @Test func aTabOfAnOldNightlyChiefHomeOpensItsChat() async throws {
        let (base, current, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let chiefHost = ChiefHomeAcpmux.host(muxHome: current.muxHome), oldHost = ChiefHomeAcpmux.host(muxHome: old)
        let record = AgentSessionRef(host: oldHost, session: kept, harness: "claude")

        // This Mac's Chief, never another machine's: no refusal, no "belongs to another machine".
        #expect(AgentPaneHostKind(record, localHost: local, chiefHost: chiefHost, listedHere: true) == .chief)
        #expect(AgentTabStore.hostRefusal(oldHost, localHost: local, chiefHost: chiefHost, daemonIsLocal: true) == nil)

        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [:], showcase: true)
        tabs.chiefHost = chiefHost
        tabs.chiefPaneHost = ChiefSubagentNamedHost(name: "chief")
        tabs.localSessionHost = ChiefSubagentNamedHost(name: "app")
        tabs.chiefHomes = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, starts in
            ChiefSubagentNamedHost(name: starts ? "old-home, started" : "old-home")
        }

        // The old home's acpmux keeps the chat: the tab attaches there. No brain holds that home,
        // so its daemon starts again when it ended.
        #expect(await reached(tabs.chiefTabHost(oldHost), session: kept) == "old-home, started")
        // A session that home does not keep runs on this Mac's acpmux.
        #expect(await reached(tabs.chiefTabHost(oldHost), session: "01a1610c-24e0-75a3-8440-e4bcf537a4ba") == "app")
        // The app's own Chief home keeps its pane host.
        #expect(await reached(tabs.chiefTabHost(chiefHost), session: kept) == "chief")
    }

    /// A Chief home made after the first lookup is found too.
    @Test func aHomeMadeAfterTheFirstLookupIsFound() async throws {
        let (base, _, _) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), rescanInterval: .zero, environment: { _ in nil }) { _, _ in ChiefSubagentNamedHost(name: "later-home") }
        let later = base.appendingPathComponent("com.cmuxterm.app.debug.25262.later", isDirectory: true)
        let laterHost = ChiefHomeAcpmux.host(muxHome: later)
        let pane = ChiefHomeSessionHost(host: laterHost, homes: directory, fallback: ChiefSubagentNamedHost(name: "app"))
        #expect(await reached(pane, session: kept) == "app")
        try FileManager.default.createDirectory(at: later.appendingPathComponent("acpmux/sessions/\(kept)", isDirectory: true),
                                                withIntermediateDirectories: true)
        #expect(await reached(pane, session: kept) == "later-home")
    }

    @Test func anOldChiefHomeWarmsItsRestoredChatThroughItsAcpmux() async throws {
        let (base, _, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let warm = ChiefSubagentWarmHost()
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, _ in warm }
        let pane = ChiefHomeSessionHost(host: ChiefHomeAcpmux.host(muxHome: old), homes: directory,
                                        fallback: ChiefSubagentNamedHost(name: "app"))

        try await pane.warm(sessionIds: [kept])
        #expect(await warm.warmed == [[kept]])
    }

    @Test func endSessionsTargetsOnlyLaunchWarmedChiefHomes() async throws {
        let (base, _, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let warm = ChiefSubagentWarmHost()
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, _ in warm }
        #expect(await directory.endLaunchSessions(waitForShutdown: false, end: { _, _ in await warm.endAgents() }).isEmpty)
        let pane = ChiefHomeSessionHost(host: ChiefHomeAcpmux.host(muxHome: old), homes: directory,
                                        fallback: ChiefSubagentNamedHost(name: "app"))
        try await pane.warm(sessionIds: [kept])
        let results = await directory.endLaunchSessions(waitForShutdown: true, end: { _, _ in await warm.endAgents() })
        #expect(results.count == 1)
        #expect(await warm.ends == 1)
        #expect(await directory.endLaunchSessions(waitForShutdown: true, end: { _, _ in await warm.endAgents() }).isEmpty)
    }

    @Test func fallbackOnlyWarmingNeverEndsTheOldHomesUnrelatedDaemon() async throws {
        let (base, _, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let own = ChiefSubagentWarmHost(), fallback = ChiefSubagentWarmHost()
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, _ in own }
        let pane = ChiefHomeSessionHost(host: ChiefHomeAcpmux.host(muxHome: old), homes: directory, fallback: fallback)
        try await pane.warm(sessionIds: ["01a1610c-24e0-75a3-8440-e4bcf537a4ba"])
        #expect(await own.warmed.isEmpty)
        #expect(await fallback.warmed.count == 1)
        #expect(await directory.endLaunchSessions(waitForShutdown: false, end: { _, _ in await own.endAgents() }).isEmpty)
        #expect(await own.ends == 0)
    }

    @Test func anAttachedOlderHomeIsNeverEndedEvenAfterLaunchWarming() async throws {
        let (base, _, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let warm = ChiefSubagentWarmHost()
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, _ in warm }
        let pane = ChiefHomeSessionHost(host: ChiefHomeAcpmux.host(muxHome: old), homes: directory, fallback: ChiefSubagentNamedHost(name: "app"))
        try await pane.warm(sessionIds: [kept])
        let alias = base.appendingPathComponent("attached-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: old.appendingPathComponent("acpmux"))
        let results = await directory.endLaunchSessions(waitForShutdown: false, excludingAttachedHome: alias,
                                                        end: { _, _ in await warm.endAgents() })
        #expect(results.isEmpty)
        #expect(await warm.ends == 0)
    }

    /// A Chief home whose brain host runs (another build that is open) owns its acpmux: a tab of
    /// that home only attaches to it, never starts it (cx-ebm.54). That is read at each handshake:
    /// a build that opens after the first lookup, or quits, changes it.
    @Test func aLiveBuildsChiefAcpmuxIsOnlyAttached() async throws {
        let (base, _, old) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let lockPath = old.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, starts in
            ChiefSubagentNamedHost(name: starts ? "starts" : "attaches")
        }
        let pane = ChiefHomeSessionHost(host: ChiefHomeAcpmux.host(muxHome: old), homes: directory, fallback: ChiefSubagentNamedHost(name: "app"))
        // No brain holds the home: its daemon may start for the tab.
        #expect(await reached(pane, session: kept) == "starts")
        // That build opens: the tab only attaches now.
        let lock = try #require(ChiefMigration.HostLock(path: lockPath))
        #expect(await reached(pane, session: kept) == "attaches")
        // It quits again.
        lock.release()
        #expect(await reached(pane, session: kept) == "starts")
    }

    /// A Chief home no longer on this Mac: its chat is looked for in this Mac's acpmux, never
    /// refused as another machine's.
    @Test func aChiefHostWithNoHomeHereAttachesToThisMacsAcpmux() async throws {
        let (base, current, _) = try homes()
        defer { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        let gone = "chief:deadbeef"
        let record = AgentSessionRef(host: gone, session: kept, harness: "claude")
        #expect(AgentPaneHostKind(record, localHost: local, chiefHost: ChiefHomeAcpmux.host(muxHome: current.muxHome),
                                  listedHere: true) == .chief)
        let directory = ChiefHomeDirectory(parents: [base], work: BackgroundWork(), environment: { _ in nil }) { _, _ in ChiefSubagentNamedHost(name: "home") }
        #expect(await reached(ChiefHomeSessionHost(host: gone, homes: directory, fallback: ChiefSubagentNamedHost(name: "app")), session: kept) == "app")
    }

    /// Another machine's tree is that machine's: a `chief:` host there is its Chief, so the tab
    /// still attaches through that machine's daemon.
    @Test func aChiefTabInAnotherMachinesTreeStaysThatMachines() {
        let record = AgentSessionRef(host: "chief:01c91c5e", session: kept, harness: "claude")
        #expect(AgentPaneHostKind(record, localHost: local, chiefHost: "chief:b902d10e", listedHere: false) == .remote)
        // The app's own Chief home is this Mac's wherever the tab is listed (as before).
        let own = AgentSessionRef(host: "chief:b902d10e", session: kept, harness: "claude")
        #expect(AgentPaneHostKind(own, localHost: local, chiefHost: "chief:b902d10e", listedHere: false) == .chief)
    }
}
