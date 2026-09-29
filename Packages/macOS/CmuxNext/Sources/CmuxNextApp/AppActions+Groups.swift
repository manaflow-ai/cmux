import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTabs

extension AppActions {
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
