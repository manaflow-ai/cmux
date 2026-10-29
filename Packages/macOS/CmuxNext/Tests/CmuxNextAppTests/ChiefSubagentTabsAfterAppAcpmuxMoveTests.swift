import Foundation
import Testing
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextHomeEngine
import CmuxNextWakeups

/// Lawrence, 2026-10-21: "i keep seeing this issue" ("This chat isn't available. It was deleted,
/// or it's on a machine that isn't connected."). #22900 moved NIGHTLY's Chief onto the app's
/// acpmux, and every Chief subagent tab then attached there. The subagents started before the
/// move (359 open tabs on the reporter's Mac) still run, or are kept, in the Chief home's own
/// acpmux, so the app's daemon lacked their sessions and each pane said the chat was gone.
/// A tab's session that the Chief home's own acpmux keeps must attach there; any other session
/// (every subagent since the move, every new chat) attaches to the app's acpmux.
struct ChiefSubagentTabsAfterAppAcpmuxMoveTests {
    private struct Reached: Error {
        let host: String
    }

    /// A pane host that only says it was reached.
    private struct NamedHost: AgentPaneHostProviding {
        let name: String
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw Reached(host: name) }
        func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
        func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
    }

    private func reached(_ host: any AgentPaneHostProviding, session: String) async -> String? {
        do {
            _ = try await host.handshake(sessionId: session)
            return nil
        } catch let reached as Reached {
            return reached.host
        } catch {
            return nil
        }
    }

    @Test func aSubagentTabFromBeforeTheMoveAttachesToTheChiefHomesOwnAcpmux() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chief-tabs-after-move-\(UUID().uuidString)/chief/default", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let home = ChiefHome(root: root, isolated: false, buildID: ChiefHome.nightlyBundleID)
        try #require(home.usesAppAcpmux)
        // The old daemon is not running (no socket): its session is kept on disk.
        let old = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc"
        try FileManager.default.createDirectory(at: home.acpmuxHome.appendingPathComponent("sessions/\(old)", isDirectory: true),
                                                withIntermediateDirectories: true)
        let chief = ChiefHomeAcpmux(home: home, local: NamedHost(name: "app"), work: BackgroundWork(label: "test.chief-tabs"), ensureHost: {},
                                    ownHost: { _ in NamedHost(name: "chief-own") })

        #expect(await reached(chief.paneHost, session: old) == "chief-own")
        // A subagent started since the move runs on the app's acpmux.
        #expect(await reached(chief.paneHost, session: "01a1610c-24e0-75a3-8440-e4bcf537a4ba") == "app")
        // An older subagent tab recorded with this Mac's host reaches the same daemon.
        #expect(await reached(chief.localRouter(NamedHost(name: "app")), session: old) == "chief-own")
        #expect(await reached(chief.localRouter(NamedHost(name: "app")), session: "new-chat") == "app")
    }
}
