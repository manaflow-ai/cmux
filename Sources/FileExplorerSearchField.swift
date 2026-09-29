import AppKit

final class FileExplorerSearchField: SidebarSearchField {
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    var onFocus: (() -> Void)?
    /// F4 (+1) and Shift-F4 (-1): the next or previous match.
    var onNavigateMatch: ((Int) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if handleOpenSelectionShortcut(event) { return }
        if handleMatchNavigation(event) { return }
        if let delta = searchFieldMoveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleOpenSelectionShortcut(event) || handleMatchNavigation(event) || super.performKeyEquivalent(with: event)
    }

    /// F4 reaches the field editor as a key the text system does not bind,
    /// so the field handles it before AppKit drops it.
    func handleMatchNavigation(_ event: NSEvent) -> Bool {
        guard let onNavigateMatch,
              let delta = FileSearchKeys.matchNavigationDelta(for: event),
              let editor = currentEditor(),
              window?.firstResponder === editor else { return false }
        onNavigateMatch(delta)
        return true
    }

    private func searchFieldMoveDelta(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandOrOption = !flags.intersection([.command, .option]).isEmpty
        if flags.contains(.control), !hasCommandOrOption {
            switch event.keyCode {
            case 45: return 1
            case 35: return -1
            default: return nil
            }
        }
        guard flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.keyCode {
        case 125: return 1
        case 126: return -1
        default: return nil
        }
    }
}
