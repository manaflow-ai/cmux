public import AppKit
public import CmuxSidebar

/// The file-explorer search field: an `NSSearchField` subclass that surfaces
/// focus, cancel, vertical-move, and commit intents through closures so the app
/// can wire them to the file-explorer outline/results selection without
/// subclassing AppKit itself. The owning view instantiates the field and assigns
/// the closures; the field translates key events (Escape, arrow/Control-N/P, and
/// Return/Enter) into those callbacks and forwards everything else to `super`.
public final class FileExplorerSearchField: NSSearchField {
    /// Where this search field is hosted; used by app-side shortcut routing.
    public var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    /// Invoked when the user presses Escape while the field is first responder.
    public var onCancel: (() -> Void)?
    /// Invoked with `+1` (down) or `-1` (up) when the user requests a selection move.
    public var onMoveSelection: ((Int) -> Void)?
    /// Invoked when the user presses Return or the numeric-keypad Enter.
    public var onCommit: (() -> Void)?
    /// Invoked when the field gains first-responder status.
    public var onFocus: (() -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
        }
        return result
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = searchFieldMoveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        super.keyDown(with: event)
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
