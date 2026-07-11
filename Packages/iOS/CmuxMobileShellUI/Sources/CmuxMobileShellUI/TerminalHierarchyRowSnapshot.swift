import CmuxMobileShellModel

struct TerminalHierarchyRowSnapshot: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let title: String
    let duplicateOrdinal: Int?
    let isSelected: Bool
    let isReady: Bool
    let canClose: Bool
    let requiresCloseConfirmation: Bool
}
