import CmuxMobileShellModel

struct TerminalPickerRowSnapshot: Identifiable, Equatable {
    let id: MobileTerminalPreview.ID
    let name: String
    let isSelected: Bool
    let canDelete: Bool
}
