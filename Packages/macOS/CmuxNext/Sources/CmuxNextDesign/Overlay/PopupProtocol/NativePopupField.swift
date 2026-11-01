import Foundation

/// NativePopupField on the native popup wire.
public struct NativePopupField: Codable, Equatable, Sendable {
    public var `id`: String
    public var `value`: String
    public var `placeholder`: String
    public var `disabled`: Bool?
    public var `submitOnReturn`: Bool?
    public var `autoHighlight`: NativePopupAutoHighlight?
    public var `completeOnTab`: Bool?
    public var `editSequence`: Int?

    public init(id: String, value: String, placeholder: String, disabled: Bool? = nil, submitOnReturn: Bool? = nil, autoHighlight: NativePopupAutoHighlight? = nil, completeOnTab: Bool? = nil, editSequence: Int? = nil) {
        self.id = id
        self.value = value
        self.placeholder = placeholder
        self.disabled = disabled
        self.submitOnReturn = submitOnReturn
        self.autoHighlight = autoHighlight
        self.completeOnTab = completeOnTab
        self.editSequence = editSequence
    }
}
