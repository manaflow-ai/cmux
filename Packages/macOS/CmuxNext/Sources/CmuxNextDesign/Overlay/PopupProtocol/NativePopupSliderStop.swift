import Foundation

/// NativePopupSliderStop on the native popup wire.
public struct NativePopupSliderStop: Codable, Equatable, Sendable {
    public var `value`: String
    public var `label`: String
    public var `description`: String?
    public var `accessibilityLabel`: String?

    public init(value: String, label: String, description: String? = nil, accessibilityLabel: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
        self.accessibilityLabel = accessibilityLabel
    }
}
