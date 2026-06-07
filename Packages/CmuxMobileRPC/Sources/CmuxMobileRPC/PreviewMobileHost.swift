public import CmuxMobileShellModel

/// Static preview fixtures used for SwiftUI previews and disconnected fallback.
public struct PreviewMobileHost {
    private init() {}

    /// The placeholder host name shown when previewing.
    public static let hostName = "cmux-macbook"

    /// Stable source-Mac device id for the synthetic preview workspaces.
    ///
    /// The aggregated list partitions by source-Mac device id, so the preview
    /// host needs a stable non-empty key (distinct from any real paired Mac) for
    /// its synthetic workspaces to land in their own partition rather than the
    /// no-device bucket.
    public static let deviceID = "preview-mac"

    /// A small set of preview workspaces with terminals, tagged to the preview
    /// Mac so they partition under ``deviceID`` in the aggregated list.
    public static let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
                MobileTerminalPreview(id: "terminal-tui", name: "TUI"),
            ],
            sourceMacDeviceID: deviceID,
            sourceMacDisplayName: hostName
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ],
            sourceMacDeviceID: deviceID,
            sourceMacDisplayName: hostName
        ),
    ]
}
