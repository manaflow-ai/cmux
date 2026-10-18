import AppKit
import SwiftUI

extension View {
    /// Publishes the "Get started" card's checklist and button actions to the
    /// `debug.cloud_getting_started.*` socket verbs. A no-op in release builds.
    func cloudGettingStartedDebugProbe(
        checklist: CloudGettingStartedChecklist,
        actions: @escaping () -> CloudGettingStartedActions
    ) -> some View {
#if DEBUG
        modifier(CloudDebugGettingStartedProbe.Publisher(checklist: checklist, actions: actions))
#else
        self
#endif
    }
}

#if DEBUG
/// The `debug.cloud_getting_started.*` socket verbs' view of the Cloud panel's
/// "Get started" card: the checklist each mounted panel derives, and the same
/// action bundle its buttons call.
@MainActor
final class CloudDebugGettingStartedProbe {
    static let shared = CloudDebugGettingStartedProbe()

    /// One mounted panel section. Plain storage: nothing observes it, so
    /// publishing never invalidates a view.
    struct Entry {
        var checklist: CloudGettingStartedChecklist
        var actions: () -> CloudGettingStartedActions
        weak var window: NSWindow?
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []

    func publish(_ entry: Entry, id: UUID) {
        if entries[id] == nil { order.append(id) }
        entries[id] = entry
    }

    func remove(id: UUID) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    /// The key window's panel, else the most recently mounted one.
    func current(keyWindow: NSWindow?) -> Entry? {
        if let keyWindow, let id = order.last(where: { entries[$0]?.window === keyWindow }) {
            return entries[id]
        }
        return order.last.flatMap { entries[$0] }
    }

    var mountedCount: Int { entries.count }

    // MARK: Actions

    enum Action: String, CaseIterable {
        case dismiss
        case pressCurrent = "press_current"
        case copyCommand = "copy_command"
    }

    /// What pressing the current step's primary control does, mirroring
    /// `CloudGettingStartedCard.currentStepBody`.
    enum Press: Equatable {
        case openSecrets
        case createMachine
        case openLocalAgent
        case openRepository
        /// The step only offers a command to copy.
        case noButton
    }

    static func press(for step: CloudGettingStartedChecklist.Step?, actions: CloudGettingStartedActions) -> Press {
        switch step {
        case .addKeys: return actions.openSecrets == nil ? .noButton : .openSecrets
        case .createMachine: return .createMachine
        case .startAgent:
            if actions.openRepository != nil { return .openRepository }
            return actions.openLocalAgent == nil ? .noButton : .openLocalAgent
        case nil: return .noButton
        }
    }

    /// The command the current step's copy button copies, if it shows one.
    static func command(for step: CloudGettingStartedChecklist.Step?, actions: CloudGettingStartedActions) -> String? {
        switch step {
        case .addKeys: return actions.openSecrets == nil ? CloudGettingStartedChecklist.importKeysCommand : nil
        case .startAgent: return CloudGettingStartedChecklist.startAgentCommand()
        case .createMachine, nil: return nil
        }
    }

    // MARK: State

    static func state(_ entry: Entry?, mountedCount: Int) -> [String: Any] {
        guard let entry else {
            return ["mounted": false, "visible": false, "mounted_count": mountedCount]
        }
        let checklist = entry.checklist
        let actions = entry.actions()
        var state: [String: Any] = [:]
        state["mounted"] = true
        state["mounted_count"] = mountedCount
        state["visible"] = checklist.isVisible
        state["complete"] = checklist.isComplete
        state["completed_count"] = checklist.completedCount
        state["total_count"] = checklist.totalCount
        state["steps"] = checklist.steps.map { step -> [String: Any] in
            [
                "id": step.rawValue,
                "title": step.title,
                "done": checklist.isDone(step),
                "current": checklist.current == step,
            ]
        }
        state["current_step"] = checklist.current?.rawValue
        state["current_detail"] = checklist.current?.detail
        state["current_press"] = "\(press(for: checklist.current, actions: actions))"
        state["current_command"] = command(for: checklist.current, actions: actions)
        state["window_number"] = entry.window?.windowNumber
        return state
    }

    /// The panel section's view modifier: publishes on appear and on every
    /// checklist change (never from `body`), and withdraws on disappear.
    struct Publisher: ViewModifier {
        let checklist: CloudGettingStartedChecklist
        let actions: () -> CloudGettingStartedActions
        @State private var id = UUID()
        /// A reference, so learning the window never writes view state.
        @State private var host = HostWindow()

        func body(content: Content) -> some View {
            content
                .background(WindowAccessor { window in
                    host.window = window
                    CloudDebugGettingStartedProbe.shared.attach(window: window, id: id)
                })
                .onChange(of: checklist, initial: true) { _, checklist in
                    CloudDebugGettingStartedProbe.shared.publish(
                        Entry(checklist: checklist, actions: actions, window: host.window),
                        id: id
                    )
                }
                .onDisappear { CloudDebugGettingStartedProbe.shared.remove(id: id) }
        }
    }

    @MainActor
    final class HostWindow {
        weak var window: NSWindow?
    }

    func attach(window: NSWindow, id: UUID) {
        entries[id]?.window = window
    }
}
#endif
