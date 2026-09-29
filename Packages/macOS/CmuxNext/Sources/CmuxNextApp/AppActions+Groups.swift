import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTabs

extension AppActions {
    static func bindTabGroups(_ services: AppServices) {
        let registry = services.registry
        func run(_ invocation: ActionInvocation, _ make: (TabGroupID) -> TabGroupCommand?) {
            let scope = scope(services, invocation)
            guard let pane = scope.pane, let raw = scope.tabGroupID, let command = make(TabGroupID(raw)) else { return }
            pane.run(command)
        }
        registry.bind("tabGroup.newTab", invoke: { run($0) { .newTab($0) } })
        registry.bind("tabGroup.ungroup", invoke: { run($0) { .ungroup($0) } })
        registry.bind("tabGroup.close", invoke: { run($0) { .close($0) } })
        registry.bind("tabGroup.save", invoke: { run($0) { .save($0) } })
        registry.bind("tabGroup.unsave", invoke: { run($0) { .unsave($0) } })
        registry.bind("tabGroup.moveToNewWindow", invoke: { run($0) { .moveToNewWindow($0) } })
        registry.bind("tabGroup.rename", invoke: { invocation in
            guard let name = invocation["name"]?.stringValue else { return }
            run(invocation) { .rename($0, name: name) }
        })
        registry.bind("tabGroup.setColor", invoke: { invocation in
            guard let color = invocation["color"]?.stringValue.flatMap(GroupColor.init(rawValue:)) else { return }
            run(invocation) { .setColor($0, color) }
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "tabGroup.color.\(color.rawValue)"), invoke: { run($0) { .setColor($0, color) } })
        }
        registry.bind("tabGroup.toggleCollapsed", invoke: { invocation in
            let scope = scope(services, invocation)
            guard let pane = scope.pane, let raw = scope.tabGroupID else { return }
            pane.handle(.toggleGroupCollapsed(TabGroupID(raw)))
        })
        registry.bind("tabGroup.create", invoke: { invocation in
            guard let (pane, id) = scope(services, invocation).tab else { return }
            pane.handle(.createGroup(TabGroupItem(id: TabGroupID(UUID().uuidString.lowercased())), tabs: [id]))
        })
    }

    static func bindBrowser(_ services: AppServices) {
        let registry = services.registry
        func chrome(_ invocation: ActionInvocation = ActionInvocation()) -> BrowserChromeView? {
            if case .browser(let entry) = scope(services, invocation).pane?.currentContent { return entry.chrome }
            return nil
        }
        let commands: [(String, BrowserChromeCommand)] = [
            ("browserBack", .goBack), ("browserForward", .goForward), ("browserReload", .reload),
            ("browserZoomIn", .zoomIn), ("browserZoomOut", .zoomOut), ("browserZoomReset", .resetZoom),
            ("focusBrowserAddressBar", .focusAddressBar),
        ]
        for (id, command) in commands {
            registry.bind(ActionID(rawValue: id), isEnabled: { chrome() != nil }, invoke: { chrome($0)?.perform(command) })
        }
    }
}
