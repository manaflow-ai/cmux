import AppKit
import CmuxNextAgentActivity
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Files dropped into a chat whose agent runs on an ssh peer (acpmux peering) go to that peer
/// (`_acpmux/file_put`), not to this Mac's Chat Uploads, whose paths that agent cannot open.
@MainActor @Suite struct AgentPeerUploadsTests {
    @Test func aPeerChatGetsThePeerUploaderAndItsDropsAreNeverThisMacsPaths() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", session = "peer-\(UUID().uuidString)"
        // A chat of this Mac's acpmux, which mirrors the peer's session.
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        services.agentTabs.sessions[tab] = session
        AgentLaneStore.shared.lanes[session] = AgentActivityLane(id: session, name: "huge-blue/fix", title: "fix", peer: "huge-blue",
                                                                 parent: nil, state: .idle, since: nil, error: nil)
        defer { AgentLaneStore.shared.lanes[session] = nil }

        #expect(AgentPeerUploads.target(tab: tab, services: services)?.machine == "huge-blue")
        #expect(AgentPeerUploads.target(tab: tab, services: services)?.session == session)
        #expect(services.agentTabs.uploader?(tab) != nil)
        #expect(services.agentTabs.localPaths?(tab) == false)

        // The same tab once its chat is this Mac's: saved here, Finder drops linked where they are.
        AgentLaneStore.shared.lanes[session] = AgentActivityLane(id: session, name: "fix", title: "fix", peer: nil,
                                                                 parent: nil, state: .idle, since: nil, error: nil)
        #expect(AgentPeerUploads.target(tab: tab, services: services) == nil)
        #expect(services.agentTabs.uploader?(tab) != nil)
        #expect(services.agentTabs.localPaths?(tab) == true)
    }

    @Test func eachFileGoesInTurnAndTheReplyNamesItsPathOnThePeer() async throws {
        let files = [AgentPaneUpload(name: "state.sqlite", data: Data([0, 1])), AgentPaneUpload(name: "state.sqlite", data: Data([2]))]
        var sent: [(String, Data)] = []
        let reply = await AgentPeerUploads.upload(files, machine: "huge-blue") { name, data in
            sent.append((name, data))
            return "/home/me/.acpmux/uploads/s/\(sent.count)/\(name)"
        }
        #expect(sent.map(\.0) == ["state.sqlite", "state.sqlite"])
        #expect(sent.map(\.1) == [Data([0, 1]), Data([2])])
        #expect(reply["ok"] as? Bool == true)
        let uploads = try #require((reply["value"] as? [String: Any])?["uploads"] as? [[String: Any]])
        #expect(uploads.map { $0["name"] as? String } == ["state.sqlite", "state.sqlite"])
        #expect(uploads.map { $0["path"] as? String } == ["/home/me/.acpmux/uploads/s/1/state.sqlite", "/home/me/.acpmux/uploads/s/2/state.sqlite"])
    }

    @Test func anOlderPeerAnswersThatTheChatTakesNoUploads() async {
        for refusal: any Error in [AcpmuxRPCError(code: -32601, name: "filePut.unsupported", message: "Method not found"),
                                   AgentPaneFilePutFailure.unsupported] {
            let reply = await AgentPeerUploads.upload([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], machine: "huge-blue") { _, _ in
                throw refusal
            }
            #expect(Self.code(reply) == "unsupported", "\(reply)")
        }
        let failed = await AgentPeerUploads.upload([AgentPaneUpload(name: "a.txt", data: Data("x".utf8))], machine: "huge-blue") { _, _ in
            throw AgentPaneFilePutFailure.failed
        }
        #expect(Self.code(failed) == "upload_failed")
    }

    @Test func peerTransportAllowsFilesLargerThanTheFormerFrameCap() {
        #expect(AgentPaneUpload.maximumPeerFileBytes > 64 * 1024 * 1024)
    }

    private static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }
}
