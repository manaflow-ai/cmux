#if os(iOS)
import CmuxMobileShellModel

/// One app-owned terminal destination exposed to GPT through an opaque ID.
struct MobileShellVoiceTarget: Equatable, Hashable, Sendable {
    let workspaceID: MobileWorkspacePreview.ID
    let terminalID: MobileTerminalPreview.ID
    let computerName: String
    let workspaceName: String
    let terminalName: String
    let currentDirectory: String?
    let isFocused: Bool
    let isReady: Bool
}
#endif
