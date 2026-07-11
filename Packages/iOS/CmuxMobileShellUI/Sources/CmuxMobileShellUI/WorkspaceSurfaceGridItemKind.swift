import CmuxMobileShellModel

/// The remote or phone-local surface represented by a grid item.
enum WorkspaceSurfaceGridItemKind: Equatable {
    case terminal(MobileTerminalPreview.ID)
    case browser
}
