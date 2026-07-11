import CmuxMobileShellModel

/// Admits one reorder mutation until its authoritative refresh completes.
struct TerminalHierarchyReorderGate: Equatable {
    private(set) var activePaneID: MobilePanePreview.ID?

    var isActive: Bool { activePaneID != nil }

    mutating func begin(paneID: MobilePanePreview.ID) -> Bool {
        guard activePaneID == nil else { return false }
        activePaneID = paneID
        return true
    }

    mutating func finish(paneID: MobilePanePreview.ID) {
        guard activePaneID == paneID else { return }
        activePaneID = nil
    }
}
