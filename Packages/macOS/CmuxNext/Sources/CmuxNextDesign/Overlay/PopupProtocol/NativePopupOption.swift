import Foundation

/// NativePopupOption on the native popup wire.
public struct NativePopupOption: Codable, Equatable, Sendable {
    public var `id`: String
    public var `label`: String
    public var `disabled`: Bool?

    public init(id: String, label: String, disabled: Bool? = nil) {
        self.id = id
        self.label = label
        self.disabled = disabled
    }
}
