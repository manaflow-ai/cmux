import CmuxNextCompat
import os

/// One window's pass over the band's items: it writes each item's value (`SidebarModel.itemInfo`) and the hidden
/// apps from the app's state. The app's sidebar bridge makes it in the turn that makes the sidebar, and the
/// first pass runs in that turn, so the model has the values before the window is ordered in (`SidebarFirstFrame`).
/// The task only follows the later changes.
@MainActor public final class SidebarSectionsPass {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.firstFrame")
    private let model: SidebarModel
    private let pass: @MainActor () -> Void
    private var following: Task<Void, Never>?

    /// `read` reads the app's state, tracked; `values` makes the items' values and the hidden apps of what it read.
    /// Runs the pass once, now. After each change of what `read` read, a task runs it again; `hold` ends with it.
    public init<Inputs: Sendable>(model: SidebarModel, hold: Task<Void, Never>, read: @escaping @MainActor @Sendable () -> Inputs,
                                  values: @escaping @MainActor (Inputs) -> ([LayoutItemID: SidebarItemInfo], Set<String>)) {
        self.model = model
        let write: @MainActor (Inputs) -> Void = { inputs in
            let (made, suppressed) = values(inputs)
            var infos = made
            // An item the band still lists keeps its value until the rows pass takes it out (an unpin: this pass can run first).
            for section in model.layout.sections {
                for item in section.items where infos[item.id] == nil { infos[item.id] = model.itemInfo[item.id] }
            }
            if model.itemInfo != infos { model.itemInfo = infos }
            if model.suppressedApps != suppressed { model.suppressedApps = suppressed }
        }
        pass = { write(read()) }
        let (first, later) = ObservationStream.current(read)
        write(first)
        // task-owner: the app's sidebar bridge (cancelled in its teardown); event-driven (Observation)
        following = Task { [weak self] in
            for await inputs in later {
                // The window closed: the bridge and this pass are gone, stop observing.
                guard self != nil else { return }
                write(inputs)
            }
        }.cancelling(hold)
    }

    /// Runs the pass now.
    public func run() { pass() }

    /// Runs the pass now if a band item has no value: a pin that the band got in this turn draws its value in
    /// the frame that gets its place. Each item has its value at a space switch, which pays no pass here.
    public func ensureValues() {
        if !SidebarFirstFrame(model).isComplete { pass() }
    }

    /// Called before the window is ordered in: the model has each band item's value. The window is made and shown
    /// in the turn of the first pass; a window shown later can be one hop ahead of the task, so this runs the pass
    /// if a value is not there. An item that still has none is a logged fault, not a trap: the pass makes a value
    /// for each item of the layout owner's document, and the model's layout can hold an item that document does
    /// not (a layout that a test writes to the model, an owner set after the sidebar was made).
    public func completeFirstFrame() {
        ensureValues()
        let faults = SidebarFirstFrame(model).faults
        guard !faults.isEmpty else { return }
        let kinds = Set(faults.map(\.ref.kind)).sorted().joined(separator: ", ")
        Self.logger.fault("a window is ordered in with \(faults.count, privacy: .public) band items that have no value (kinds: \(kinds, privacy: .public))")
    }

    public func cancel() { following?.cancel() }
}
