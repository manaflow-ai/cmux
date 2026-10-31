import CmuxNextSidebar
import CmuxNextWakeups

/// The sidebar's selection, applied with the rows that show it (bd cx-8g3sn).
/// The window selects a new workspace (Cmd-N) in the turn it joins the
/// window, but the selection and the rows reach the sidebar through two
/// observations: shown first, the selection cleared the old row's fill for a
/// few frames before the new row came in. A workspace selection with no row
/// yet waits for the next rows (`flush`), or ``limit``. A helper beside
/// SidebarBridge (its type is at its size limit).
@MainActor
final class SidebarSelectionHold {
    /// A selected workspace the rows never list (another space's) waits no longer.
    static let limit: Duration = .milliseconds(250)
    private let model: SidebarModel
    private var held: SidebarItem??
    private let backstop = DemandTimer(owner: "SidebarSelectionHold.limit")

    init(model: SidebarModel) {
        self.model = model
    }

    /// The window's selection changed to `selected`.
    func offer(_ selected: SidebarItem?) {
        if case .workspace(let id)? = selected, model.selectedItem != selected, !model.lists(id) {
            held = .some(selected)
            backstop.schedule(after: Self.limit) { @MainActor [weak self] in self?.flush() }
            return
        }
        held = nil
        backstop.cancel()
        apply(selected)
    }

    /// The rows changed: a held selection shows with them, in this turn.
    func flush() {
        guard let item = held else { return }
        held = nil
        backstop.cancel()
        apply(item)
    }

    private func apply(_ selected: SidebarItem?) {
        guard model.selectedItem != selected else { return }
        model.selectedItem = selected
        // A pinned workspace's tile is selected as its row is: it starts the selection (and a Shift range).
        model.selection = model.shownWorkspaceID.map { [$0] } ?? []
    }
}
