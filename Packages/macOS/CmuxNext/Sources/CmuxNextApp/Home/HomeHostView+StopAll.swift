import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The stop button and Stop All Agents (the coordinator 2026-10-20): a click,
/// Esc and Cmd-. stop only the Chief's turn (the shared stop action);
/// Option-click stops all agents of the Chief this Home shows, and the File
/// menu and the palette those of the front window's Chief Home
/// (HomeChiefActions). The toast lists what stopped and offers Restart.
extension HomeHostView {
    /// The stop button's actions: a click runs the shared stop action;
    /// Option-click stops all agents of this Home's own Chief (never another
    /// Home's in the same window).
    func wireStopButton(_ registry: ActionRegistry) {
        transcript.onStop = { _ = registry.perform(HomeChiefControl.stopAction, invocation: ActionInvocation(origin: .user)) }
        transcript.onStopAll = { [weak self] in self?.stopAllAgents() }
        transcript.stopToolTip = HomeStopAllStrings.stopToolTip
    }

    /// `chief.stop {all}` on this Home's Chief, then the toast: what stopped,
    /// with Restart when subagents did. A failure, or a Home that shows no
    /// Chief (or a hosted cloud Chief, which has no stop), beeps.
    func stopAllAgents() {
        let control = chiefControl
        guard showsChiefOnScreen, !control.isHosted, let window else { return NSSound.beep() }
        // task-owner: one chief.stop {all}, then the toast; ends with the answer
        Task { @MainActor [weak window] in
            switch await control.stopAll() {
            case .failure:
                NSSound.beep()
            case .success(let answer):
                guard let window else { return }
                let names = answer.subagents
                let action = names.isEmpty ? nil : CmuxToast.Action(title: HomeStopAllStrings.restart)
                let toast = CmuxToast(id: "home.stopAllAgents", message: HomeStopAllStrings.message(for: answer), action: action)
                let handle = CmuxToastCenter.shared.show(toast, in: window)
                handle.onAction = {
                    // task-owner: one chief.stop {restart}; ends with its answer
                    Task { @MainActor in if await control.restart(names) != nil { NSSound.beep() } }
                }
            }
        }
    }
}
