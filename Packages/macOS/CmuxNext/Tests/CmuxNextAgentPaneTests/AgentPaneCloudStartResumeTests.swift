import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A page built again while its pane's Cloud start ran (a health reload of a page that stopped answering, a hibernated
/// page shown again) gets the start in its handshake and hears its end, never an empty New Tab with the prompt gone.
@MainActor
struct AgentPaneCloudStartResumeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static let key = "0b8d3a8e-6c1f-4b5e-9d55-0d6c2f1f2a11"

    private static func start() -> AgentPaneCloudStart {
        AgentPaneCloudStart(task: "list the files", cwd: "/Users/dev/paint", harness: "claude", key: key)
    }

    @Test func aRunningStartKeepsItsPromptAndStepsForTheNextPage() {
        let model = AgentPaneModel(host: NoHost())
        model.beginCloudStartResume(Self.start())
        model.noteCloudStartProgress(.object(["key": .string(Self.key), "step": .string("folder")]))
        model.noteCloudStartProgress(.object(["key": .string(Self.key), "step": .string("opening"), "machine": .string("cloud-chats-7")]))
        // Another start's push is not this one's.
        model.noteCloudStartProgress(.object(["key": .string("other"), "step": .string("machine")]))
        let record = model.cloudStartResumeForPage()
        #expect(record?.task == "list the files")
        #expect(record?.cwd == "/Users/dev/paint")
        #expect(record?.harness == "claude")
        #expect(record?.progress?["step"] == .string("opening"))
        #expect(record?.progress?["machine"] == .string("cloud-chats-7"))
        #expect(record?.ended == nil)
    }

    @Test func aFailureIsKeptWithItsWordsAndAnOpenedChatIsNoStart() {
        let model = AgentPaneModel(host: NoHost())
        model.beginCloudStartResume(Self.start())
        let failure = AgentPaneReply.failure(code: "cloud_start_failed", message: "Couldn't copy the folder to cloud-chats-7.",
                                             details: nil, retryable: true, origin: "native")
        let ended = model.endCloudStartResume(key: Self.key, reply: failure)
        #expect(ended == .init(ok: false, code: "cloud_start_failed", message: "Couldn't copy the folder to cloud-chats-7.", retryable: true))
        #expect(model.cloudStartResumeForPage()?.ended == ended)
        // A later push of the ended start changes nothing.
        model.noteCloudStartProgress(.object(["key": .string(Self.key), "step": .string("opening")]))
        #expect(model.cloudStartResumeForPage()?.progress == nil)

        model.beginCloudStartResume(Self.start())
        #expect(model.endCloudStartResume(key: Self.key, reply: AgentPaneReply.success(["machine": "cloud-chats-7"])).ok)
        #expect(model.cloudStartResumeForPage() == nil)
    }

    @Test func anotherStartsEndOrAnOldRecordIsNotShown() {
        let model = AgentPaneModel(host: NoHost())
        model.beginCloudStartResume(Self.start())
        model.endCloudStartResume(key: "other", reply: AgentPaneReply.success())
        #expect(model.cloudStartResumeForPage() != nil)
        #expect(model.cloudStartResumeForPage(now: Date().addingTimeInterval(31 * 60)) == nil)
        #expect(model.cloudStartResume == nil, "an old record is dropped")
    }

    @Test func theHandshakeCarriesTheRecord() throws {
        var handshake = AgentPaneHandshake(transport: .mock)
        handshake.cloudStartResume = AgentPaneCloudStartResume(Self.start(), now: Date(timeIntervalSince1970: 1))
        let coded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any]
        let record = coded?["cloudStartResume"] as? [String: Any]
        #expect(record?["key"] as? String == Self.key)
        #expect(record?["task"] as? String == "list the files")
        #expect(record?["startedAtMs"] as? Double == 1000)
    }
}
