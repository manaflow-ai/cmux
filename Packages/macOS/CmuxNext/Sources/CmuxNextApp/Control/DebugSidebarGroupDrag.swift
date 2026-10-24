#if DEBUG
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_group_drag {phase, group?, y?, drop?, window?}` (group drag captures, Lawrence 2026-10-23): holds
/// a group drag in the window's sidebar through the path a pointer takes. `phase: "lift"` presses `group`'s header
/// (a `GroupID`, e.g. `g-perf` of the `tallGroup` nested fixture); `"move"` moves the pointer to list y `y`; `"end"`
/// lets go (`drop: true`) or cancels, and gives the sidebar its document drag back. Answers where it pressed, the
/// lifted card's top and height and the open gap, in list coordinates.
@MainActor
struct DebugSidebarGroupDrag {
    let services: AppServices

    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        DebugSidebarGroupDrag(services: services).run(params)
    }

    func run(_ params: [String: JSONValue]) -> JSONValue {
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        let step: SidebarContainerView.GroupDragFixtureStep
        switch params["phase"]?.stringValue {
        case "lift":
            guard let group = params["group"]?.stringValue else { return .object(["error": .string("lift needs group")]) }
            step = .lift(GroupID(group))
        case "move":
            guard let y = params["y"]?.doubleValue else { return .object(["error": .string("move needs y")]) }
            step = .move(y: y)
        case "end":
            step = .end(drop: params["drop"]?.boolValue ?? false)
        default:
            return .object(["error": .string("phase is lift, move or end")])
        }
        let answer = sidebar.container.groupDragFixture(step)
        if case .end = step { sidebar.model.docDrag = SidebarDocWiring.docMachines(services.machines).drag() }
        return .object(answer.mapValues { .number($0) })
    }
}
#endif
