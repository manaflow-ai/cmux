@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import Foundation

// The group editor, attach events and the settled-world checks.
extension InputWorld {
    /// The tab group editor bubble: a key panel that is a child of the window.
    func openGroupEditor(_ window: SimWindow) {
        setKey(.groupEditor(window.index))
    }

    func closeGroupEditor(_ window: SimWindow) {
        setKey(.window(window.index))
    }

    /// An attach event for a live terminal, valid for its current phase.
    func attach(_ n: Int, _ event: Int) {
        let live = terminals.filter { !$0.value.machine.isClosed }.keys.sorted()
        guard !live.isEmpty else { return }
        let tab = live[n % live.count]
        guard var terminal = terminals[tab] else { return }
        let machine = terminal.machine
        let pendingAttach: TerminalAttachMachine<Int>.Pending? = switch machine.phase {
        case .attaching(let pending), .reattaching(let pending): pending
        default: nil
        }
        let link = terminal.nextLink
        let event: TerminalAttachMachine<Int>.Event? = switch event % 9 {
        case 0: pendingAttach.flatMap { $0.link == nil ? .opened(link, attempt: $0.attempt) : nil }
        case 1: pendingAttach.flatMap { $0.link == nil ? .openFailed(attempt: $0.attempt) : nil }
        case 2: pendingAttach?.link.map { .replayDelivered($0) }
        case 3: (machine.liveLink ?? pendingAttach?.link).map { .ended($0, .overflow) }
        case 4: .visibility(!machine.visible)
        case 5: pendingAttach.map { .opened(link, attempt: $0.attempt - 1) }
        case 6: .focused
        // Another client sized the terminal (tmux "latest" geometry).
        case 7: machine.liveLink.map { .gridAnnounced($0, CellSize(cols: 7 + Int(chunk % 50), rows: 5)) }
        default: (machine.liveLink ?? pendingAttach?.link).map { .ended($0, .surfaceGone) }
        }
        guard let event else { return }
        if case .opened = event { terminal.nextLink += 1 }
        terminals[tab] = terminal
        reduceTerminal(tab, event)
    }

    // MARK: Observation

    func observation() -> InputObservation {
        let keyWindow: InputObservation.KeyWindow = switch key {
        case .none: .none
        case .window(let index): .window(windows[index].id)
        case .childPage(let index, _): .childPage(window: windows[index].id)
        case .palette: .panel(window: nil, kind: "PalettePanel")
        case .sheet(let index): .sheet(window: windows[index].id)
        case .groupEditor(let index): .panel(window: windows[index].id, kind: "TabGroupEditorPanel")
        }
        return InputObservation(
            windows: windows.map { window in
                let ghostty: [String] = if window.isKey, case .content(let pane) = window.responder, let tab = window.presented[pane],
                                           self.tab(tab)?.kind == .terminal { [tab] } else { [] }
                return InputObservation.Window(
                    id: window.id, model: window.focus.state, responder: window.responder, responderClass: nil,
                    isKey: window.isKey, layoutFocus: window.layoutFocus, ghosttyFocused: ghostty, childPage: window.childPage,
                    presented: window.presented,
                    childWindowTabs: window.presented.values.filter { self.tab($0)?.isChromium == true }.sorted(),
                    hasSheet: window.hasSheet
                )
            },
            keyWindow: keyWindow,
            paletteOpen: paletteOpen,
            activeWindow: active.map { windows[$0].id },
            context: context
        )
    }

    /// World invariants plus the omnibar rule (F8), once nothing is waiting
    /// for a frame.
    func checkWorld() {
        guard isSettled else { return }
        stats.worldChecks += 1
        violations += InputInvariants.world(observation()).violations
        for window in windows {
            for (pane, tab) in window.presented where self.tab(tab)?.kind == .browser {
                let focused = omnibars[tab]?.hasFocus ?? false
                let responderThere = window.responder == .addressBar(pane: pane)
                if focused != responderThere {
                    violations.append(InputViolation(invariant: .omnibarTarget, window: window.id,
                                                     detail: "omnibar \(tab) focused \(focused), responder \(InputInvariants.describe(window.responder))"))
                }
                // Under an overlay the applier leaves the field alone until it closes.
                if focused, window.focus.state.overlays.isEmpty, window.focus.state.underlying != .addressBar(pane: pane, tab: tab) {
                    violations.append(InputViolation(invariant: .omnibarTarget, window: window.id,
                                                     detail: "omnibar \(tab) editing while the model targets \(window.focus.state.underlying.kind)"))
                }
            }
        }
    }
}
