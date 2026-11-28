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
}
