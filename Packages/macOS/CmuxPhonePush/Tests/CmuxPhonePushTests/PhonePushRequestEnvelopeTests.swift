import Foundation
import Testing
@testable import CmuxPhonePush

@Suite struct PhonePushRequestEnvelopeTests {
    @Test func notificationWireIdentityIncludesMacBuildInstance() throws {
        let payload = Self.notifyPayload()

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

    @Test func notificationEncodesWorkspaceGroupFields() throws {
        let payload = Self.notifyPayload(
            workspaceGroupId: "group-id",
            workspaceGroupName: "Backend"
        )

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_000
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )

        #expect(object["workspaceGroupId"] as? String == "group-id")
        #expect(object["workspaceGroupName"] as? String == "Backend")
    }

    @Test func notificationOmitsAbsentWorkspaceGroupFields() throws {
        let payload = Self.notifyPayload()

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_000
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )

        #expect(object["workspaceGroupId"] == nil)
        #expect(object["workspaceGroupName"] == nil)
    }

    @Test func notificationNeverEncodesAGroupNameWithoutItsGroupId() throws {
        let payload = Self.notifyPayload(workspaceGroupName: "Backend")

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_000
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )

        #expect(object["workspaceGroupId"] == nil)
        #expect(object["workspaceGroupName"] == nil)
    }

    @Test func hiddenContentKeepsWorkspaceGroupIdAndDropsItsName() throws {
        let payload = Self.notifyPayload(
            workspaceGroupId: "group-id",
            workspaceGroupName: "Backend",
            hideContent: true
        )

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_000
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )

        #expect(object["workspaceGroupId"] as? String == "group-id")
        #expect(object["workspaceGroupName"] == nil)
    }

    @Test func dismissNeverCarriesWorkspaceGroupFields() throws {
        let payload = PhonePushPayload(
            kind: .dismiss,
            title: "",
            subtitle: "",
            body: "",
            replyShape: "",
            workspaceId: nil,
            workspaceGroupId: "group-id",
            workspaceGroupName: "Backend",
            surfaceId: nil,
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: "device",
            macInstanceTag: "nightly",
            notificationId: nil,
            notificationIds: ["notification"],
            badgeCount: 0,
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

        #expect(object["workspaceGroupId"] == nil)
        #expect(object["workspaceGroupName"] == nil)
    }

    @Test func workspaceGroupFieldsShipTheNameOnlyWithVisibleContent() {
        let groupId = UUID()

        let visible = PhonePushPayload.workspaceGroupFields(
            groupId: groupId,
            groupName: "Backend",
            hideContent: false
        )
        let hidden = PhonePushPayload.workspaceGroupFields(
            groupId: groupId,
            groupName: "Backend",
            hideContent: true
        )

        #expect(visible.workspaceGroupId == groupId.uuidString)
        #expect(visible.workspaceGroupName == "Backend")
        #expect(hidden.workspaceGroupId == groupId.uuidString)
        #expect(hidden.workspaceGroupName == nil)
    }

    @Test func workspaceGroupFieldsRequireAGroupId() {
        let fields = PhonePushPayload.workspaceGroupFields(
            groupId: nil,
            groupName: "Backend",
            hideContent: false
        )

        #expect(fields.workspaceGroupId == nil)
        #expect(fields.workspaceGroupName == nil)
    }

    private static func notifyPayload(
        workspaceGroupId: String? = nil,
        workspaceGroupName: String? = nil,
        hideContent: Bool = false
    ) -> PhonePushPayload {
        PhonePushPayload(
            kind: .notify,
            title: "Build complete",
            subtitle: "",
            body: "Ready",
            replyShape: "none",
            workspaceId: "workspace",
            workspaceGroupId: workspaceGroupId,
            workspaceGroupName: workspaceGroupName,
            surfaceId: "surface",
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: "device",
            macInstanceTag: "nightly",
            notificationId: "notification",
            notificationIds: [],
            badgeCount: 1,
            hideContent: hideContent
        )
    }
}
