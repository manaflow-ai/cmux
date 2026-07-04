import CmuxMobileShellModel
import Foundation

#if os(iOS) && DEBUG
struct WorkspaceDetailPreviewWorkspaceBuilder {
    private let actionCapabilities = MobileWorkspaceActionCapabilities(
        supportsWorkspaceActions: true,
        supportsReadStateActions: true
    )

    func make(
        id: MobileWorkspacePreview.ID,
        macDeviceID: String? = nil,
        macDisplayName: String? = nil,
        windowID: String? = nil,
        name: String,
        isPinned: Bool = false,
        groupID: MobileWorkspaceGroupPreview.ID? = nil,
        previewText: String? = nil,
        previewAt: Date? = nil,
        lastActivityAt: Date? = nil,
        hasUnread: Bool = false,
        terminals: [MobileTerminalPreview]
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: id,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
            windowID: windowID,
            name: name,
            isPinned: isPinned,
            groupID: groupID,
            previewText: previewText,
            previewAt: previewAt,
            lastActivityAt: lastActivityAt,
            hasUnread: hasUnread,
            terminals: terminals
        )
        workspace.actionCapabilities = actionCapabilities
        return workspace
    }
}
#endif
