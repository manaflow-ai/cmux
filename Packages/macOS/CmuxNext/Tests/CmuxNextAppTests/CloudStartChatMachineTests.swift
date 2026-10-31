@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// What stays in the App of a `cloud.startChat` send. Which machine it takes, a retry's pin and
/// the send's keys are cmux-tui's and tested there (`link/start_chat_cli/tests.rs`, on Linux).
@Suite
@MainActor
struct CloudStartChatMachineTests {
    /// A folder the page named is copied only as the pane checked it.
    @Test func aPageNamedFolderIsCopiedOnlyAsItsCheckedUploadRoot() throws {
        let folder = try #require(CloudMoveFolder(chat: "/Users/me/src/paint"))
        var start = try #require(AgentPaneCloudStart(params: ["task": "t", "cwd": "/Users/me/src/paint", "key": UUID().uuidString]))
        #expect(!CloudStartChat.uploads(folder, as: start))
        start.uploadRoot = folder.root
        #expect(CloudStartChat.uploads(folder, as: start))
        start.uploadRoot = "/Users/me/src/paint/sub"
        #expect(!CloudStartChat.uploads(folder, as: start))
        // The tab's own folder (no `cwd`) is copied as Move to Cloud copies it.
        let tabs = try #require(AgentPaneCloudStart(params: ["task": "t", "key": UUID().uuidString]))
        #expect(CloudStartChat.uploads(folder, as: tabs))
    }

    /// The create's key is the plan's, so a retry after a lost create answer never makes a second VM.
    @Test func aNewMachineIsCreatedUnderThePlansKey() {
        let request = CloudStartChat.createRequest(key: "cloud-start-chat-k", sizedFor: nil)
        #expect(request.idempotencyKey == "cloud-start-chat-k")
        #expect(!request.wasSent)
    }

    /// The plan reads every machine as the pick needs it, in the App's order.
    @Test func thePlanRequestCarriesTheSendAndWhoIsSignedIn() throws {
        let text = CloudStartChat.planRequest(key: "K", user: "user-leo", loaded: true, machines: [])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["key"] as? String == "K")
        #expect(object["user"] as? String == "user-leo")
        #expect(object["loaded"] as? Bool == true)
        #expect((object["machines"] as? [Any])?.isEmpty == true)
        let signedOut = try #require(try JSONSerialization.jsonObject(with: Data(CloudStartChat.planRequest(key: "K", user: nil, loaded: false, machines: []).utf8)) as? [String: Any])
        #expect(signedOut["user"] == nil)
    }

    /// Not behind Labs (Leo, 2026-10-30: "that seems dumb. i dont like putting so much stuff in
    /// labs"): only Cloud off by policy and a signed-out account refuse.
    @Test func aCloudStartIsRefusedOnlyWhenCloudIsOffOrNobodyIsSignedIn() {
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: true) == nil)
        #expect(CloudStartChat.refusal(cloudDisabled: false, signedIn: false) == "not_signed_in")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: true) == "cloud_disabled")
        #expect(CloudStartChat.refusal(cloudDisabled: true, signedIn: false) == "cloud_disabled")
    }
}
