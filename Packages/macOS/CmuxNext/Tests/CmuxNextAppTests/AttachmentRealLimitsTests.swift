import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// Leo, 2026-10-26: "why the FUCK SHOULD THERE BE A FUCKING SIZE CAP ANYWAYS ... I ALREADY SAID WE
/// NEED ARBITARRILY LARGE FILES OF ANY TYPE". The huge-files web test drives a stand-in host, so it
/// never met the app's own limits: the bridge decoder refused a begin over 1 GiB and a batch of more
/// than 64 files, and the local stager refused over 1 GiB. These go through the production path a
/// page's `chat.upload.*` call takes: `AgentPaneRequest(body:)`, then the stager the app composes for
/// the tab (`AgentTabs.uploadStager`, wired by `AppActions.bind`), for a chat on this Mac.
@MainActor
@Suite(.serialized)
struct AttachmentRealLimitsTests {
    /// Over 4 GiB: past every 32-bit and 1 GiB limit the paths ever had.
    static let huge = 4 * 1024 * 1024 * 1024 + 7

    @Test func aBeginOverFourGiBIsTakenAndItsFirstChunkLands() async throws {
        try await Self.withLocalChat { stage, _ in
            let begin = try #require(Self.decoded(["name": "huge.bin", "size": Self.huge]))
            let reply = await stage(begin)
            let value = try #require(Self.value(reply), "refused: \(reply)")
            let token = try #require(value["token"] as? String)
            #expect((value["size"] as? Int) == Self.huge)
            let chunk = try #require(Self.decoded(["token": token, "offset": 0, "data": Data(count: 512 * 1024).base64EncodedString()],
                                                  method: "chat.upload.chunk"))
            #expect((Self.value(await stage(chunk))?["offset"] as? Int) == 512 * 1024)
            _ = await stage(.cancel(token: token))
        }
    }

    @Test func sixtyFiveFilesInOneBatchEachLandOnThisMac() async throws {
        try await Self.withLocalChat { stage, session in
            let files = (0..<65).map { (name: "file-\($0).txt", data: Data("file \($0)\n".utf8)) }
            let manifest: [[String: Any]] = files.map { ["name": $0.name, "size": $0.data.count] }
            var batchToken: String?
            var paths: [String] = []
            for (index, file) in files.enumerated() {
                var params: [String: Any] = ["name": file.name, "size": file.data.count]
                if index == 0 { params["batch"] = manifest }
                if let batchToken { params["batchToken"] = batchToken }
                let begin = try #require(Self.decoded(params), "the decoder refused file \(index)")
                let begun = try #require(Self.value(await stage(begin)), "the stager refused file \(index)")
                if index == 0 { batchToken = try #require(begun["batchToken"] as? String) }
                let token = try #require(begun["token"] as? String)
                let chunk = try #require(Self.decoded(["token": token, "offset": 0, "data": file.data.base64EncodedString()],
                                                      method: "chat.upload.chunk"))
                #expect(Self.value(await stage(chunk)) != nil)
                let finished = try #require(Self.value(await stage(.finish(token: token))), "file \(index) did not finish")
                paths.append(try #require(finished["path"] as? String))
            }
            #expect(paths.count == 65)
            #expect(Set(paths).count == 65)
            for (path, file) in zip(paths, files) {
                #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == file.data)
            }
            if let root = AgentChatUploads.root { AgentChatUploads.remove(session: session, in: root) }
        }
    }

    @Test func aBatchNamingFilesOverFourGiBIsTaken() async throws {
        try await Self.withLocalChat { stage, _ in
            let manifest: [[String: Any]] = (0..<65).map { ["name": "part-\($0).bin", "size": Self.huge] }
            let begin = try #require(Self.decoded(["name": "part-0.bin", "size": Self.huge, "batch": manifest]))
            let value = try #require(Self.value(await stage(begin)))
            #expect(value["batchToken"] is String)
            _ = await stage(.cancel(token: try #require(value["token"] as? String)))
        }
    }

    // MARK: Helpers

    /// `chat.upload.*` as the bridge decodes the page's message; nil when the decoder refuses it.
    static func decoded(_ params: [String: Any], method: String = "chat.upload.begin") -> AgentPaneUploadStageRequest? {
        guard case .uploadStage(let request) = AgentPaneRequest(body: ["method": method, "params": params]) else { return nil }
        return request
    }

    static func value(_ reply: [String: Any]) -> [String: Any]? {
        reply["ok"] as? Bool == true ? reply["value"] as? [String: Any] : nil
    }

    /// One app for the suite: an `AppServices` that goes away leaves its observers registered on
    /// the running application, and the next one's teardown crashed the test process.
    private static var services: AppServices?

    private static func app() -> AppServices {
        if let services { return services }
        _ = NSApplication.shared
        let made = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(made)
        services = made
        return made
    }

    /// The app's stager for a chat whose folder is on this Mac (a tab and session of its own),
    /// and that chat's session.
    static func withLocalChat(_ body: (_ stage: @MainActor (AgentPaneUploadStageRequest) async -> [String: Any], _ session: String) async throws -> Void)
        async throws {
        let services = app()
        let tab = "tab-\(UUID().uuidString)", session = "real-limits-\(UUID().uuidString.lowercased())"
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        services.agentTabs.sessions[tab] = session
        defer { services.agentTabs.sessions[tab] = nil }
        let stager = try #require(services.agentTabs.uploadStager?(tab), "no stager for a chat on this Mac")
        try await body({ await stager($0, session) }, session)
    }
}
