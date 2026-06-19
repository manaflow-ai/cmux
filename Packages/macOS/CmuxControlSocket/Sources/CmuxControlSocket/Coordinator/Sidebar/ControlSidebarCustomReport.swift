/// A Sendable snapshot of one discovered or requested custom-sidebar file, the
/// control-side twin of the app's `CustomSidebarValidationEntry`. Carries
/// exactly the fields the `sidebar.custom.*` reply payload exposes so the
/// worker can format the wire `sidebars` array without importing the app-side
/// validator.
public struct ControlSidebarCustomReportEntry: Sendable, Equatable {
    /// The sidebar name (file base name).
    public let name: String

    /// The resolved sidebar file path (`fileURL.path`).
    public let path: String

    /// The sidebar file format raw value (`"swift"` / `"json"`).
    public let kindRawValue: String

    /// Whether validation succeeded (`errorMessage == nil`).
    public let isValid: Bool

    /// The human-readable validation error, or `nil` when valid.
    public let errorMessage: String?

    /// Creates a report entry.
    ///
    /// - Parameters:
    ///   - name: The sidebar name.
    ///   - path: The resolved file path.
    ///   - kindRawValue: The file-format raw value.
    ///   - isValid: Whether validation succeeded.
    ///   - errorMessage: The validation error, if any.
    public init(name: String, path: String, kindRawValue: String, isValid: Bool, errorMessage: String?) {
        self.name = name
        self.path = path
        self.kindRawValue = kindRawValue
        self.isValid = isValid
        self.errorMessage = errorMessage
    }
}

/// A Sendable snapshot of a custom-sidebar validation report, the control-side
/// twin of the app's `CustomSidebarValidationReport` plus the resolved sidebars
/// directory. ``ControlSidebarCustomWorker`` formats every `sidebar.custom.*`
/// reply payload from this value (directory, counts, the per-sidebar array);
/// the app-side conformer produces it by running the real validator on the
/// socket-worker thread.
public struct ControlSidebarCustomReport: Sendable, Equatable {
    /// The resolved custom-sidebars directory path
    /// (`CmuxExtensionSidebarSelection.customSidebarsDirectory.path`).
    public let directoryPath: String

    /// The per-sidebar entries, in the validator's order.
    public let entries: [ControlSidebarCustomReportEntry]

    /// Creates a report snapshot.
    ///
    /// - Parameters:
    ///   - directoryPath: The resolved sidebars directory path.
    ///   - entries: The per-sidebar entries.
    public init(directoryPath: String, entries: [ControlSidebarCustomReportEntry]) {
        self.directoryPath = directoryPath
        self.entries = entries
    }

    /// The number of valid entries (the legacy `report.validCount`).
    public var validCount: Int {
        entries.filter(\.isValid).count
    }

    /// The number of invalid entries (the legacy `report.errorCount`).
    public var errorCount: Int {
        entries.count - validCount
    }

    /// Every entry's name in order (the legacy `report.names`); gates the
    /// reload notification post.
    public var names: [String] {
        entries.map(\.name)
    }

    /// The names of entries that passed validation (the legacy
    /// `report.validNames`); drives `reloaded_count` / `reloaded_names`.
    public var validNames: [String] {
        entries.filter(\.isValid).map(\.name)
    }
}
