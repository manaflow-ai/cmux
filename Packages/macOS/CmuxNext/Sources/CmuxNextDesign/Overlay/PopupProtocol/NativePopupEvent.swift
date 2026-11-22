import Foundation

/// NativePopupEvent on the native popup wire.
public struct NativePopupEvent: Codable, Equatable, Sendable {
    public var `type`: NativePopupEventType
    public var `popupId`: String
    public var `revision`: Int
    public var `id`: String?
    public var `value`: String?
    public var `reason`: String?
    public var `editSequence`: Int?

    public init(type: NativePopupEventType, popupId: String, revision: Int, id: String? = nil, value: String? = nil, reason: String? = nil, editSequence: Int? = nil) {
        self.type = type
        self.popupId = popupId
        self.revision = revision
        self.id = id
        self.value = value
        self.reason = reason
        self.editSequence = editSequence
    }
}
