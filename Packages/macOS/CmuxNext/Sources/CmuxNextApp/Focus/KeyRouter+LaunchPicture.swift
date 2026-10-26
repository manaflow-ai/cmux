import AppKit
import CmuxNextFocus
import CmuxNextLaunch
import CmuxNextTerminal

// Keys typed while a window shows its launch picture (p08-startup-061). A Command chord, or a Control chord bound to
// an action, runs its registry action as usual: it changes the model in its turn. Any other key for a focused
// terminal whose live view is not built waits in that terminal's stand-in buffer (`LaunchPictureKeys`), which raises
// the pane's build slice to the next frame; no key builds the window in its turn.
extension KeyRouter {
    /// Whether `event` waits for the focused terminal of `window`, still a picture. A terminal that is live and has
    /// the keyboard, with nothing typed for it waiting, takes its keys on the usual path.
    func holdsForLaunchPicture(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, !chords.isPending, waitsForTerminal(event) else { return false }
        let (controller, kind) = focus(for: window)
        guard let controller, kind == .content, case .terminal(let pane, let tab) = controller.focus.state.resolved else { return false }
        let target = LaunchPictureKeys.Target(window: controller.state.id, pane: pane, tab: tab)
        guard launchPictureKeys.holds(window: target.window) else { return false }
        if !launchPictureKeys.isHolding(target), terminalHasKeyboard(target, in: controller.window ?? window) { return false }
        decided.add(event)
        trace?("launch picture: the key waits for terminal \(tab)")
        launchPictureKeys.hold(event, for: target)
        return true
    }

    /// A key a terminal takes as typing: not a Command chord, and not a Control chord bound to an action.
    private func waitsForTerminal(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if flags.contains(.command) { return false }
        return !flags.contains(.control) || registry.resolveShortcut(for: event) == nil
    }

    /// `target`'s terminal view has the keyboard of `shell`.
    private func terminalHasKeyboard(_ target: LaunchPictureKeys.Target, in shell: NSWindow) -> Bool {
        guard let surface = liveSurface(of: target) else { return false }
        return shell.firstResponder === surface
    }

    /// Gives `events` to `target`'s terminal view, in order, when the pane shows it; false keeps them waiting.
    func deliverLaunchPictureKeys(_ events: [NSEvent], to target: LaunchPictureKeys.Target) -> Bool {
        guard let surface = liveSurface(of: target) else { return false }
        for event in events { surface.keyDown(with: event) }
        return true
    }

    /// `target`'s terminal view, while its pane shows it in a window.
    private func liveSurface(of target: LaunchPictureKeys.Target) -> TerminalSurfaceView? {
        guard let controller = services?.windows.controller(for: target.window),
              let pane = controller.content?.paneController(key: target.pane), pane.currentTabKey == target.tab,
              case .terminal(let entry)? = pane.currentContent else { return nil }
        let surface = entry.session.surfaceView
        return surface.window == nil ? nil : surface
    }
}
