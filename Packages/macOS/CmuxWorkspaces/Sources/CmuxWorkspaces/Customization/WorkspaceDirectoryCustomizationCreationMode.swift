/// How a freshly-created workspace participates in directory customization.
public enum WorkspaceDirectoryCustomizationCreationMode: Equatable, Sendable {
    /// Do not associate the workspace with a directory customization record.
    case disabled
    /// Track the workspace directory so later user title/color changes persist.
    case trackDirectory
}
