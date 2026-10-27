import Foundation
import Testing
@testable import CmuxPhonePush

@Suite struct PhonePushRequestEnvelopeTests {
    @Test func notificationWireIdentityIncludesMacBuildInstance() throws {
        let payload = PhonePushPayload(
            kind: .notify,
            title: "Build complete",
            subtitle: "",
            body: "Ready",
            replyShape: "none",
            workspaceId: "workspace",
            surfaceId: "surface",
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: "device",
            macInstanceTag: "nightly",
            notificationId: "notification",
            notificationIds: [],
            badgeCount: 1,
            hideContent: false
        )

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_000
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )

        #expect(object["macDeviceId"] as? String == "device")
        #expect(object["macInstanceTag"] as? String == "nightly")
    }

    /// Hidden content leaves the text out and sends the localized placeholder body; with no
    /// host-app table (the test runner) that is the English default, on every platform.
    @Test func hiddenContentSendsThePlaceholderBody() throws {
        let payload = PhonePushPayload(
            kind: .notify,
            title: "Secret title",
            subtitle: "Secret subtitle",
            body: "Secret body",
            replyShape: "none",
            workspaceId: "workspace",
            surfaceId: "surface",
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: "device",
            macInstanceTag: "nightly",
            notificationId: "notification",
            notificationIds: [],
            badgeCount: 1,
            hideContent: true
        )

        let envelope = try PhonePushRequestEnvelope(payload: payload, expirationEpochSeconds: 1_750_000_000)
        let object = try #require(JSONSerialization.jsonObject(with: envelope.body) as? [String: Any])

        #expect(object["title"] as? String == "cmux")
        #expect(object["subtitle"] as? String == "")
        #expect(object["body"] as? String == "New terminal activity")
    }
}
