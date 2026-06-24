import Foundation

/// A model choice shown by the Open Chat composer.
public struct OpenChatModelOption: Sendable, Hashable {
    /// Stable picker value encoded as `<backend>:<provider>/<model>`.
    public let id: String

    /// User-facing brand and model label shown in the picker.
    public let label: String

    /// Backend launcher id that cmux can drive directly.
    public let backendProviderID: String

    /// Model id passed to the backend, or `nil` for that backend's default.
    public let modelID: String?

    /// OpenCode provider id for brokered models, or `nil` for direct backends.
    public let openCodeProviderID: String?

    /// Whether this option is selected when no stored user choice exists.
    public let isSelected: Bool

    /// Creates a model picker option.
    ///
    /// - Parameters:
    ///   - id: Stable picker value encoded as `<backend>:<provider>/<model>`.
    ///   - label: User-facing brand and model label shown in the picker.
    ///   - backendProviderID: Backend launcher id that cmux can drive directly.
    ///   - modelID: Model id passed to the backend, or `nil` for the default.
    ///   - openCodeProviderID: OpenCode provider id for brokered models.
    ///   - isSelected: Whether this option is selected by default.
    public init(
        id: String,
        label: String,
        backendProviderID: String,
        modelID: String? = nil,
        openCodeProviderID: String? = nil,
        isSelected: Bool
    ) {
        self.id = id
        self.label = label
        self.backendProviderID = backendProviderID
        self.modelID = modelID
        self.openCodeProviderID = openCodeProviderID
        self.isSelected = isSelected
    }
}
