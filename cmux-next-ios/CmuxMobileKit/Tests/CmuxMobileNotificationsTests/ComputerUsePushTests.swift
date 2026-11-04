@testable import CmuxMobileNotifications
import Foundation
import Testing
import UserNotifications

/// Computer Use pushes: the device hub's `cmuxComputerUse` notice and a Mac's
/// `computer_use` payload, their category and buttons.
@Suite struct ComputerUsePushTests {
    func hubUserInfo(_ object: [String: Any]) -> [AnyHashable: Any] {
        ["aps": ["category": "CMUX_COMPUTER_USE_APPROVAL"], "cmuxComputerUse": object]
    }

    let valid: [String: Any] = ["v": 1, "approvalId": "0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60", "deviceId": "a5b2c3d4-0000-4000-8000-000000000007",
                                "hub": "https://cmux-device-hub-dev.debussy.workers.dev", "allowAlways": true, "answerableUntil": 1_793_400_600_000]

    @Test func theHubNoticeDecodes() throws {
        let notice = try #require(ComputerUseApprovalNotice(userInfo: hubUserInfo(valid)))
        #expect(notice.approvalID == "0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60")
        #expect(notice.deviceID == "a5b2c3d4-0000-4000-8000-000000000007" && notice.allowAlways)
        #expect(notice.answerableUntil == Date(timeIntervalSince1970: 1_793_400_600))
        #expect(notice.notificationIdentifier == "cu-0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60")
    }

    @Test func malformedNoticesAreNotRead() {
        for (key, value) in [("v", 2 as Any), ("approvalId", "" as Any), ("hub", "ftp://hub.example" as Any), ("hub", "not a url" as Any)] {
            var object = valid
            object[key] = value
            #expect(ComputerUseApprovalNotice(userInfo: hubUserInfo(object)) == nil, "\(key)")
        }
        var missing = valid
        missing["deviceId"] = nil
        #expect(ComputerUseApprovalNotice(userInfo: hubUserInfo(missing)) == nil)
        #expect(ComputerUseApprovalNotice(userInfo: ["cmuxMobile": ["kind": "permission"]]) == nil)
    }

    @Test func onlyTheConfiguredHubCounts() throws {
        let notice = try #require(ComputerUseApprovalNotice(userInfo: hubUserInfo(valid)))
        #expect(notice.isFrom(URL(string: "https://cmux-device-hub-dev.debussy.workers.dev")!))
        #expect(notice.isFrom(URL(string: "https://CMUX-device-hub-dev.debussy.workers.dev:443/")!))
        #expect(!notice.isFrom(URL(string: "https://cmux-device-hub.debussy.workers.dev")!))
        #expect(!notice.isFrom(URL(string: "http://cmux-device-hub-dev.debussy.workers.dev")!))
        #expect(!notice.isFrom(URL(string: "https://cmux-device-hub-dev.debussy.workers.dev:8443")!))
    }

    @Test func actionsMapAndRoundTrip() {
        #expect(ComputerUseApprovalAction.allCases.map(\.identifier) == ["cmux.cu.once", "cmux.cu.session", "cmux.cu.always", "cmux.cu.deny"])
        for action in ComputerUseApprovalAction.allCases {
            #expect(ComputerUseApprovalAction(identifier: action.identifier) == action)
        }
        #expect(ComputerUseApprovalAction(identifier: "cmux.allow.once") == nil)
        #expect(ComputerUseApprovalAction(identifier: UNNotificationDefaultActionIdentifier) == nil)
    }

    @Test func allowsOpenTheAppAndDenyNeedsOnlyUnlock() {
        for action in [ComputerUseApprovalAction.allowOnce, .allowSession, .allowAlways] {
            let built = action.notificationAction(requireFaceID: false)
            #expect(built.options.contains(.foreground) && built.options.contains(.authenticationRequired) && !built.options.contains(.destructive))
        }
        let deny = ComputerUseApprovalAction.deny.notificationAction(requireFaceID: false)
        #expect(!deny.options.contains(.foreground) && deny.options.contains(.authenticationRequired) && deny.options.contains(.destructive))
        // Settings → Require Face ID: Deny opens the app too, so its lock stands in front of it.
        #expect(ComputerUseApprovalAction.deny.notificationAction(requireFaceID: true).options.contains(.foreground))
        #expect(ComputerUseApprovalAction.allowOnce.title == "Allow Once" && ComputerUseApprovalAction.allowSession.title == "Allow for This Session")
    }

    @Test func bothCategoriesCarryOnceSessionDenyButNeverAlways() throws {
        let categories = PushActions().categories
        for id in ["CMUX_COMPUTER_USE_APPROVAL", "CMUX_MOBILE_COMPUTER_USE"] {
            let category = try #require(categories.first { $0.identifier == id })
            #expect(category.actions.map(\.identifier) == ["cmux.cu.once", "cmux.cu.session", "cmux.cu.deny"])
        }
    }

    @Test func aMacComputerUsePushDecodes() throws {
        let userInfo: [AnyHashable: Any] = ["cmuxMobile": [
            "v": 2, "mac": "mac-1", "macName": "Studio", "kind": "computer_use", "eventId": "cu-8b103ea20764ba906dc15f5fc3a90a99",
            "permissionId": "cu-8b103ea20764ba906dc15f5fc3a90a99", "agent": "Claude", "workspace": "api-server", "title": "Safari",
            "state": "waiting",
            "computerUse": ["always": true, "request": ["v": 1, "nonce": "6f1d", "target": ["bundle_id": "com.apple.Safari", "executable": NSNull(), "name": "Safari"],
                                                        "created_ms": 1_793_400_000_000, "digest": "ab"]],
        ] as [String: Any]]
        let payload = try #require(PushPayload(userInfo: userInfo))
        #expect(payload.kind == .computerUse && payload.category == .computerUse && payload.kind.isAsk)
        let question = try #require(payload.computerUse)
        #expect(question.always)
        #expect(question.request["target"]?["executable"] == .null && question.request["created_ms"] == .int(1_793_400_000_000))
        // Its banner names the agent and the app, then the workspace and the Mac.
        let banner = PushBanner(payload: payload)
        #expect(banner.title == "Claude wants to use Safari" && banner.subtitle == "api-server · Studio")
        // It has its own buttons; the content extension adds none.
        #expect(PushActions().plan(for: payload).isEmpty)
        // A round trip through the userInfo the service extension writes keeps the request.
        #expect(PushPayload(userInfo: payload.userInfo)?.computerUse == question)
    }

    @Test func aMacComputerUseReplyThroughTheMailbox() throws {
        let allow = try MailboxReply(computerUse: "d1", decision: "session", mac: "mac-1", id: "r1", phone: "phone-1", nonce: "n",
                                     now: Date(timeIntervalSince1970: 1000),
                                     approval: .object(["approver": .string("phone-1"), "expiresAt": .int(1120), "signature": .string("ab")]),
                                     expiresAt: 1120)
        #expect(allow.plaintext["kind"] == .string("computer_use"))
        #expect(allow.plaintext["target"] == .object(["digest": .string("d1")]))
        #expect(allow.plaintext["action"] == .object(["type": .string("allow"), "optionId": .string("session")]))
        #expect(allow.plaintext["expiresAt"] == .int(1120))
        let deny = try MailboxReply(computerUse: "d1", decision: "deny", mac: "mac-1", id: "r2", phone: "phone-1", nonce: "n",
                                    now: Date(timeIntervalSince1970: 1000), approval: nil, expiresAt: nil)
        #expect(deny.plaintext["action"] == .object(["type": .string("deny"), "optionId": .string("deny")]) && deny.plaintext["approval"] == nil)
        #expect(throws: MailboxReply.Failure.unsigned) {
            try MailboxReply(computerUse: "d1", decision: "once", mac: "m", id: "r3", phone: "p", nonce: "n", now: Date(), approval: nil, expiresAt: nil)
        }
    }
}
