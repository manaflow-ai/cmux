import AppKit

final class GhosttyPassthroughVisualEffectView: NSVisualEffectView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

func shouldAllowEnsureFocusWindowActivation(
    activeTabManager: TabManager?,
    targetTabManager: TabManager,
    keyWindow: NSWindow?,
    mainWindow: NSWindow?,
    targetWindow: NSWindow
) -> Bool {
    guard activeTabManager === targetTabManager || (keyWindow == nil && mainWindow == nil) else {
        return false
    }

    if let keyWindow {
        return keyWindow === targetWindow
    }

    if let mainWindow {
        return mainWindow === targetWindow
    }

    return true
}

extension TerminalSurface {
    @MainActor
    func applyTmuxControlEvent(_ event: TmuxControlEvent) {
        var next = tmuxControlState
        next.apply(event)
        guard next != tmuxControlState else { return }
        tmuxControlState = next
#if DEBUG
        cmuxDebugLog(
            "tmux.control surface=\(id.uuidString.prefix(5)) active=\(next.active) " +
            "event=\(next.lastEvent) panes=\(next.paneIds)"
        )
#endif
    }

    @MainActor
    func tmuxControlReportPayload() -> [String: Any] {
        tmuxControlState.debugPayload
    }

    func debugInitialCommand() -> String? {
        initialCommand
    }

    func debugTmuxStartCommand() -> String? {
        tmuxStartCommand
    }

    func debugInitialInputMetadata() -> (hasInitialInput: Bool, byteCount: Int) {
        let byteCount = initialInput?.utf8.count ?? 0
        return (byteCount > 0, byteCount)
    }

    func debugInitialInputForTesting() -> String? {
        initialInput
    }
}
