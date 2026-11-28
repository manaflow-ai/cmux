import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings

#if DEBUG
/// Debug-build control methods for extension verification without a real
/// pointer: `debug.cef.devtools` runs a DevTools method on the focused
/// Chromium tab (trusted `Input.*` events, such as a right click that opens
/// the page menu), and `debug.menu` lists the open page menu's items and can
/// choose one by title or dismiss it.
@MainActor
enum DebugExtensions {
    static func devTools(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let services, case .browser(let entry)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent,
              let tab = entry.tab as? CEFTab, let method = params["method"]?.stringValue else {
            return .object(["error": .string("no focused Chromium tab or method")])
        }
        // Trusted input counts as a user gesture: no saved password fills here after this.
        tab.markAgentDriven()
        // No DevTools method on, or toward, Chromium's own pages (plans/cmux-next/passwords.md, section 2).
        let target = params["params"]?.objectValue?["url"]?.stringValue
        if AppBrowserPage.showsRefusedPage(tab) || target.map(AgentURLPolicy.refuses) == true {
            return .object(["error": .string("forbidden: agents cannot use Chromium's own pages")])
        }
        var arguments: [String: any Sendable] = [:]
        for (key, value) in params["params"]?.objectValue ?? [:] { arguments[key] = foundation(value) }
        do {
            return .object(["result": .string(try await tab.devTools(method: method, params: arguments))])
        } catch {
            return .object(["error": .string(String(describing: error))])
        }
    }

    private static func foundation(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? Int(number) as any Sendable : number
        case .string(let string): return string
        case .array(let items): return items.map(foundation)
        case .object(let members): return members.mapValues(foundation)
        }
    }

    static func menu(_ params: [String: JSONValue], presenter: BrowserContextMenuBuilder?) -> JSONValue {
        guard let menu = presenter?.presentedMenu else { return .object(["open": .bool(false)]) }
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        if let choose = params["choose"]?.stringValue, let index = menu.items.firstIndex(where: { $0.title == choose }) {
            menu.cancelTracking()
            menu.performActionForItem(at: index)
            return .object(["open": .bool(true), "items": .array(titles.map { .string($0) }), "chose": .string(choose)])
        }
        if params["dismiss"]?.boolValue == true { menu.cancelTracking() }
        return .object(["open": .bool(true), "items": .array(titles.map { .string($0) })])
    }
}
#endif
