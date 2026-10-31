import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import Foundation
import Testing

/// A screen recording attached to a chat on this Mac that has not started yet (a new chat, the New
/// Tab page) streams to Chat Uploads like any other file (https://github.com/manaflow-ai/cmux/issues/28647).
/// The page streams every file over 24 MiB (`chat.upload.begin`, `.chunk`, `.finish`); the pane
/// refused a chat with no session as `unsupported`, which the page reads as a host too old to
/// stream: the tile said "This host cannot stream an attachment this large." with Retry, which
/// failed the same way. A chat that gets its session while the file still streams (the person
/// sent the prompt meanwhile) keeps the upload, and the file lands in that chat's folder.
@MainActor @Suite(.serialized)
struct AgentChatUploadsStageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func ask(_ model: AgentPaneModel, _ method: String, _ params: [String: Any]) async -> [String: Any] {
        await model.respond(to: AgentPaneRequest(body: ["method": method, "params": params]))
    }

    private static func value(_ reply: [String: Any]) -> [String: Any] {
        reply["value"] as? [String: Any] ?? [:]
    }

    @Test func aNewChatStreamsARecordingAndItLandsInTheChatItBecomes() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", session = "rec-\(UUID().uuidString.lowercased())"
        // A chat on this Mac with no session yet.
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        let model = AgentPaneModel(host: NoHost())
        services.agentTabs.wire(model, key: tab)
        let root = try #require(ChatUploadFolders.standard)
        defer { try? FileManager.default.removeItem(at: root.chat(session)) }

        let first = Data(repeating: 0x6d, count: 512 * 1024), second = Data([0x6f, 0x6f, 0x76])
        model.transport.gestures.record()
        let begin = await Self.ask(model, "chat.upload.begin", ["name": "Screen Recording.mov", "size": first.count + second.count])
        #expect(begin["ok"] as? Bool == true, "a chat with no session refused the upload: \(begin)")
        let token = try #require(Self.value(begin)["token"] as? String)
        let one = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": 0, "data": first.base64EncodedString()])
        #expect(Self.value(one)["offset"] as? Int == first.count)

        // The person sends the prompt while the file streams: the chat starts and gets its session.
        _ = await Self.ask(model, "chat.persistSession", ["sessionId": session])
        #expect(model.sessionId == session)
        let two = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": first.count, "data": second.base64EncodedString()])
        #expect(Self.value(two)["offset"] as? Int == first.count + second.count, "the upload stopped when the chat started: \(two)")
        let finish = await Self.ask(model, "chat.upload.finish", ["token": token])
        let path = try #require(Self.value(finish)["path"] as? String, "\(finish)")
        #expect(path.hasPrefix(root.chat(session).path + "/"))
        #expect((path as NSString).lastPathComponent == "Screen Recording.mov")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == first + second)
    }

    @Test func anotherChatsPageCannotFeedAStageOnceItsChatStarted() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", other = "tab-\(UUID().uuidString)"
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        let model = AgentPaneModel(host: NoHost()), stranger = AgentPaneModel(host: NoHost())
        services.agentTabs.wire(model, key: tab)
        services.agentTabs.wire(stranger, key: other)
        let session = "own-\(UUID().uuidString.lowercased())", strangerSession = "other-\(UUID().uuidString.lowercased())"
        let root = try #require(ChatUploadFolders.standard)
        defer {
            try? FileManager.default.removeItem(at: root.chat(session))
            try? FileManager.default.removeItem(at: root.chat(strangerSession))
        }

        model.transport.gestures.record()
        let begin = await Self.ask(model, "chat.upload.begin", ["name": "clip.mov", "size": 2])
        let token = try #require(Self.value(begin)["token"] as? String, "\(begin)")
        _ = await Self.ask(model, "chat.persistSession", ["sessionId": session])
        _ = await Self.ask(stranger, "chat.persistSession", ["sessionId": strangerSession])
        // Another started chat holding the token feeds nothing into this chat's stage.
        let fed = await Self.ask(stranger, "chat.upload.chunk", ["token": token, "offset": 0, "data": Data([1, 2]).base64EncodedString()])
        #expect(fed["ok"] as? Bool == false)
        let own = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": 0, "data": Data([1, 2]).base64EncodedString()])
        #expect(Self.value(own)["offset"] as? Int == 2, "\(own)")
    }
}
