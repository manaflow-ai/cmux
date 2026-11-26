/// Where `session.import` reads a snapshot from.
public enum ControlSessionImportSource: Sendable, Equatable {
    /// Another install's saved session, named by channel (`stable`,
    /// `nightly`, `rc`, `staging`, `debug[:tag]`) or bundle identifier.
    case channel(String)
    /// A snapshot file at an absolute path.
    case file(path: String)

    /// Whether the snapshot restores with full trust (automatic resume). Only
    /// another install's own session file does; an arbitrary file does not.
    public var isTrusted: Bool {
        if case .channel = self { return true }
        return false
    }
}

/// The outcome of `session.import`.
///
/// Failure messages are resolved in the APP conformance so they stay
/// localized; the package only carries the resolved strings.
public enum ControlSessionImportResolution: Sendable, Equatable {
    /// The snapshot was validated and reopened as additional windows.
    /// `heldBackResumeCount` counts terminals whose resume command was kept
    /// for manual restore instead of running automatically (file imports
    /// only); `droppedRemoteWorkspaceCount` counts workspaces whose SSH/cloud
    /// connection or environment from the file was dropped.
    case restored(
        sourcePath: String,
        windowCount: Int,
        heldBackResumeCount: Int,
        droppedRemoteWorkspaceCount: Int
    )
    /// The import failed. `code` is the socket error code (`not_found`,
    /// `invalid_params`, `unsupported`, `invalid_state`, `unavailable`),
    /// `path` the file involved when known.
    case failed(code: String, message: String, path: String?)
}

/// The outcome of `session.export`.
public enum ControlSessionExportResolution: Sendable, Equatable {
    /// The saved snapshot at `sourcePath` was written to `path`.
    case exported(path: String, sourcePath: String)
    /// The export failed. `code` is the socket error code (`not_found`,
    /// `already_exists`, `invalid_params`, `invalid_state`, `unavailable`),
    /// `path` the file involved when known.
    case failed(code: String, message: String, path: String?)
}
