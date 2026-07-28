/// The filesystem object an automation path argument must resolve to.
public enum CmuxActionExistingPathKind: String, Sendable, Equatable {
    /// An existing directory.
    case directory
    /// An existing regular file. Directories and special files are rejected.
    case regularFile = "regular_file"
}
