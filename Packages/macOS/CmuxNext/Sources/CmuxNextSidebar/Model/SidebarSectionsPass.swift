import CmuxNextCompat

/// One window's pass over the band's items: it writes each item's value (`SidebarModel.itemInfo`) and the hidden
/// apps from the app's state. The app's sidebar bridge makes it in the turn that makes the sidebar, and the
/// first pass runs in that turn, so the window's first frame reads the values (`SidebarFirstFrame`). The task only
/// follows the later changes.
@MainActor public final class SidebarSectionsPass {
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

    /// Called before the window is ordered in: its first frame has each band item's value. The window is made and
    /// shown in the turn of the first pass; a window shown later can be one hop ahead of the task, so this runs the
    /// pass if a value is not there, then asserts the rule.
    public func completeFirstFrame() {
        ensureValues()
        assert(SidebarFirstFrame(model).isComplete,
               "a window is ordered in with band items that have no value: \(SidebarFirstFrame(model).faults.map(\.id.rawValue))")
    }

    public func cancel() { following?.cancel() }
}
