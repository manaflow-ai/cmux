import CmuxMobileBrowser
import CmuxMobileShellModel

/// The complete browser identity set for an authoritative visible workspace list.
struct WorkspaceBrowserReconciliation {
    let identities: [BrowserWorkspaceIdentity]

    init(workspaces: [MobileWorkspacePreview]) {
        identities = workspaces.map(\.browserSurfaceIdentity)
    }
}
