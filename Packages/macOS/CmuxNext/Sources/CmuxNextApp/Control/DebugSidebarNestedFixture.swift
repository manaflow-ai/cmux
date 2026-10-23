#if DEBUG
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_nested_fixture {scenario, window?}` (nested-groups prototype): the window's sidebar shows
/// a fixture tree of groups inside groups (`SidebarNestedFixture`) at the scenario's width, with its
/// rails and drag; `scenario: "off"` brings the live rows back. Answers the scenario and the rows drawn.
@MainActor
struct DebugSidebarNestedFixture {
    let services: AppServices

    static func show(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        DebugSidebarNestedFixture(services: services).show(params)
    }

    func show(_ params: [String: JSONValue]) -> JSONValue {
        let name = params["scenario"]?.stringValue ?? "deep"
        guard let controller = services.windows.controllers.first(where: { c in params["window"]?.stringValue.map { $0 == c.state.id } ?? true })
                ?? services.windows.active else {
            return .object(["error": .string("no window")])
        }
        let sidebar = controller.sidebar
        if name == "off" {
            sidebar.container.showNestedFixture(nil)
            sidebar.rows.fixture = nil
            return .object(["scenario": .string("off")])
        }
        guard let scenario = SidebarNestedFixture.Scenario(rawValue: name) else {
            return .object(["error": .string("unknown scenario"),
                            "available": .array(SidebarNestedFixture.Scenario.allCases.map { .string($0.rawValue) })])
        }
        let fixture = SidebarNestedFixture(scenario: scenario)
        sidebar.restore(width: fixture.width, hidden: false)
        sidebar.model.filterText = ""
        sidebar.rows.fixture = fixture.sections
        sidebar.container.layoutSubtreeIfNeeded()
        sidebar.container.showNestedFixture(fixture)
        return .object(["scenario": .string(scenario.rawValue), "width": .number(fixture.width),
                        "window": .string(controller.state.id)])
    }
}
#endif
