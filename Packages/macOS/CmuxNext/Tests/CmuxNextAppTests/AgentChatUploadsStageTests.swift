import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A screen recording attached to a chat on this Mac that has not started yet (a new chat, the New
/// Tab page) streams to Chat Uploads like any other file (https://github.com/manaflow-ai/cmux/issues/28647).
/// The page streams every file it uploads (`chat.upload.begin`, `.chunk`, `.finish`); the pane
/// refused a chat with no session as `unsupported`, which the page reads as a host too old to
/// stream, so a file over 24 MiB showed "This host cannot stream an attachment this large." with
/// Retry, which failed the same way. The page host (where the agent page shows by default) did the same
/// before the pane was asked: its `cmux.agent.*` list had `chat.upload` but no `chat.upload.begin`, so it
/// answered `cmux.protocol.unknown_op`, which the page reads the same way. These go through that host, as
/// the page's calls do. A chat that gets its session while the file still streams (the person sent the
/// prompt meanwhile) keeps the upload, and the file lands in that chat's folder.
@MainActor @Suite(.serialized)
struct AgentChatUploadsStageTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The page's call `op` (`cmux.agent.<op>`) through the page host, in the old reply shape.
    private static func ask(_ model: AgentPaneModel, _ op: String, _ params: [String: Any]) async -> [String: Any] {
        let host = AgentPageProvider { _ in model }
        do {
            let value = try await host.call(AgentPageOps.namespace + op, params: JSONValue(foundation: params) ?? .null,
                                            context: PageCallContext(page: PageDescriptor.agent.id))
            return ["ok": true, "value": value.foundationObject]
        } catch let error as PageError {
            return ["ok": false, "error": ["code": error.code]]
        } catch {
            return ["ok": false, "error": ["code": "\(error)"]]
        }
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
        // Never left in the real Chat Uploads, whatever fails below.
        defer { try? FileManager.default.removeItem(at: root.root.appending(path: "staged-" + token)) }
        let one = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": 0, "data": first.base64EncodedString()])
        #expect(Self.value(one)["offset"] as? Int == first.count)

        // The person sends the prompt while the file streams: the chat starts and gets its session.
        _ = await Self.ask(model, "session.persist", ["sessionId": session])
        #expect(model.sessionId == session)
        let two = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": first.count, "data": second.base64EncodedString()])
        #expect(Self.value(two)["offset"] as? Int == first.count + second.count, "the upload stopped when the chat started: \(two)")
        let finish = await Self.ask(model, "chat.upload.finish", ["token": token])
        let path = try #require(Self.value(finish)["path"] as? String, "\(finish)")
        #expect(path.hasPrefix(root.chat(session).path + "/"))
        #expect((path as NSString).lastPathComponent == "Screen Recording.mov")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == first + second)
    }

    @Test func anotherNewChatsPageCannotFeedTheStage() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let tab = "tab-\(UUID().uuidString)", other = "tab-\(UUID().uuidString)"
        // Two chats on this Mac, neither with a session yet: both stage as "new".
        services.agentTabs.gitLink = { _ in services.agentGit.local }
        let model = AgentPaneModel(host: NoHost()), stranger = AgentPaneModel(host: NoHost())
        services.agentTabs.wire(model, key: tab)
        services.agentTabs.wire(stranger, key: other)
        let root = try #require(ChatUploadFolders.standard)

        model.transport.gestures.record()
        let begin = await Self.ask(model, "chat.upload.begin", ["name": "clip.mov", "size": 2])
        let token = try #require(Self.value(begin)["token"] as? String, "\(begin)")
        defer { try? FileManager.default.removeItem(at: root.root.appending(path: "staged-" + token)) }
        let data = Data([1, 2]).base64EncodedString()
        for method in ["chat.upload.chunk", "chat.upload.cancel"] {
            _ = await Self.ask(stranger, method, ["token": token, "offset": 0, "data": data])
        }
        let fed = await Self.ask(stranger, "chat.upload.chunk", ["token": token, "offset": 0, "data": data])
        #expect(fed["ok"] as? Bool == false)
        // The stranger's cancel left it: the chat that began it still feeds it.
        let own = await Self.ask(model, "chat.upload.chunk", ["token": token, "offset": 0, "data": data])
        #expect(Self.value(own)["offset"] as? Int == 2, "\(own)")
        _ = await Self.ask(model, "chat.upload.cancel", ["token": token])
        #expect(!FileManager.default.fileExists(atPath: root.root.appending(path: "staged-" + token).path))
    }
}
