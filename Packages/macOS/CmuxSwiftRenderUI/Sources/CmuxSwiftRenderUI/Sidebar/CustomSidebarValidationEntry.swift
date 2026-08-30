import Foundation

/// Validation result for one discovered or requested custom sidebar file.
public struct CustomSidebarValidationEntry: Equatable, Sendable {
    /// Sidebar name, derived from the file base name.
    public let name: String

    /// Resolved file URL used for validation or for a missing-file report.
    public let fileURL: URL

    /// Sidebar file format.
    public let kind: CustomSidebarFileKind

    /// Human-readable validation error, or `nil` when the sidebar is valid.
    public let errorMessage: String?

    /// Non-blocking diagnostics produced from representative sample data.
    public let warningMessages: [String]

    /// Creates a validation entry.
    public init(
        name: String,
        fileURL: URL,
        kind: CustomSidebarFileKind,
        errorMessage: String?,
        warningMessages: [String] = []
    ) {
        self.name = name
        self.fileURL = fileURL
        self.kind = kind
        self.errorMessage = errorMessage
        self.warningMessages = warningMessages
    }

    /// Whether validation succeeded.
    public var isValid: Bool { errorMessage == nil }
}
