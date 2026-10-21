import AppKit
import CmuxNextActions
import CmuxNextDesign

/// The stop button and Stop All Agents (the coordinator 2026-10-20): a click,
/// Esc and Cmd-. stop only the Chief's turn (the shared stop action);
/// Option-click, the File menu and the palette stop all agents, which only the
/// Chief's Home in the key window takes. Its toast lists what stopped and
/// offers Restart.
extension HomeHostView {
    /// Every Home view (weak): where Stop All Agents looks for the one that takes it.
    private static let homes = NSHashTable<HomeHostView>.weakObjects()

    /// The Home that takes Stop All Agents now: the Chief's Home in the key
    /// window. Nil off a Chief's Home, or for a hosted cloud Chief (no stop
    /// there), so the action is unavailable rather than a silent no-op.
    static var stopAllTarget: HomeHostView? { homes.allObjects.first { $0.takesStopAll } }

    private var takesStopAll: Bool {
        isChief && !control.isHosted && window?.isKeyWindow == true && !isHiddenOrHasHiddenAncestor
    }

    /// The stop button's actions, and this Home's place among Stop All Agents' targets.
    func wireStopButton(_ registry: ActionRegistry) {
        Self.homes.add(self)
        transcript.onStop = { _ = registry.perform(HomeChiefControl.stopAction, invocation: ActionInvocation(origin: .user)) }
        transcript.onStopAll = { _ = registry.perform(HomeChiefControl.stopAllAction, invocation: ActionInvocation(origin: .user)) }
        transcript.stopToolTip = HomeStopAllStrings.stopToolTip
    }

    /// `chief.stop {all}` on this Home's Chief, then the toast: what stopped,
    /// with Restart when subagents did. A failure beeps.
    func stopAllAgents() {
        guard takesStopAll, let window else { return NSSound.beep() }
        let control = control
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
