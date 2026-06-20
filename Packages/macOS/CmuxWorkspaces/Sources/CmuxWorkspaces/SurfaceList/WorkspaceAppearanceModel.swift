/// The per-workspace appearance sub-model: owns the custom tab-color and
/// terminal-scrollbar transition logic the legacy `Workspace` god object kept
/// inline (`setCustomColor`, `setTerminalScrollBarHidden`).
///
/// The appearance vocabulary it reads and writes (`customColor`,
/// `terminalScrollBarHidden`) is the workspace's `@Published` state, whose
/// `objectWillChange` emissions drive the UI, so the model reaches each property
/// through ``WorkspaceAppearanceHosting``, conformed by `Workspace` and injected
/// via ``attach(host:)``. The two app-coupled effects the legacy bodies made,
/// the `WorkspaceTabColorSettings.normalizedHex(_:)` settings call and the
/// `terminalScrollBarHiddenDidChangeNotification` post, also go through the
/// seam.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line call, so every call site stays byte-identical. There is no
/// observer-parity bridge here: the writes go straight through the host's own
/// `@Published` properties, preserving their emission moments exactly as the
/// legacy bodies did.
@MainActor
public final class WorkspaceAppearanceModel {
    private weak var host: (any WorkspaceAppearanceHosting)?

    /// Creates a detached model; call ``attach(host:)`` before any appearance
    /// transition runs.
    public init() {}

    /// Injects the live-workspace seam. Set at the composition point before any
    /// appearance transition runs so the reads and writes reach the workspace.
    public func attach(host: any WorkspaceAppearanceHosting) {
        self.host = host
    }

    /// Sets or clears the workspace's custom tab color, normalizing a non-nil
    /// `hex` through the host's `WorkspaceTabColorSettings.normalizedHex(_:)` and
    /// clearing it for a `nil` argument. A malformed hex normalizes to `nil`,
    /// clearing the color, exactly as the legacy body did. Faithful lift of
    /// `Workspace.setCustomColor(_:)`.
    public func setCustomColor(_ hex: String?) {
        guard let host else { return }
        if let hex {
            host.workspaceAppearanceCustomColor = host.workspaceAppearanceNormalizedColorHex(hex)
        } else {
            host.workspaceAppearanceCustomColor = nil
        }
    }

    /// Toggles the per-workspace terminal-scrollbar override, posting
    /// `terminalScrollBarHiddenDidChangeNotification` through the host only when
    /// the value actually changes. Faithful lift of
    /// `Workspace.setTerminalScrollBarHidden(_:)`.
    public func setTerminalScrollBarHidden(_ hidden: Bool) {
        guard let host else { return }
        guard host.workspaceAppearanceTerminalScrollBarHidden != hidden else { return }
        host.workspaceAppearanceTerminalScrollBarHidden = hidden
        host.workspaceAppearancePostTerminalScrollBarHiddenDidChange()
    }
}
