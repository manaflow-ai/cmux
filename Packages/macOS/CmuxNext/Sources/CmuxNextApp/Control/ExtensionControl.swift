import CmuxNextActions
import CmuxNextBrowser
import CmuxNextSettings

/// `browser.extensions`: the installed Chrome extensions of the focused
/// Chromium tab's profile (chrome://extensions data), its extension
/// shortcuts, and the tab's toolbar actions with their live badges. Read on
/// the main actor: Chromium owns the list and answers only on its UI thread.
@MainActor
enum ExtensionControl {
    static func report(_ services: AppServices) -> JSONValue {
        guard case .browser(let entry)? = ActionScope(services: services, invocation: ActionInvocation()).pane?.currentContent,
              let tab = entry.tab as? CEFTab else {
            return .object(["error": .string(ExtensionStrings.needsChromiumTab)])
        }
        let store = tab.extensionStore
        store.refresh()
        let extensions: [JSONValue] = store.extensions.map { info in
            var object: [String: JSONValue] = [
                "id": .string(info.id), "name": .string(info.name), "version": .string(info.version),
                "manifest_version": .number(Double(info.manifestVersion)), "location": .string(info.location.rawValue),
                "enabled": .bool(info.isEnabled), "pinned": .bool(info.isPinned), "has_action": .bool(info.hasAction),
                "may_modify": .bool(info.mayModify),
            ]
            if let options = info.optionsURL { object["options_url"] = .string(options.absoluteString) }
            if !info.disableReasons.isEmpty { object["disable_reasons"] = .array(info.disableReasons.map { .number(Double($0)) }) }
            return .object(object)
        }
        let commands: [JSONValue] = store.commands.map { command in
            .object(["extension_id": .string(command.extensionID), "name": .string(command.name),
                     "shortcut": .string(command.shortcut), "global": .bool(command.isGlobal)])
        }
        let actions: [JSONValue] = tab.extensionActions.map { action in
            .object(["id": .string(action.id), "title": .string(action.title), "badge": .string(action.badge),
                     "badge_color": .string(action.badgeColor), "enabled": .bool(action.isEnabled),
                     "pinned": .bool(action.isPinned), "has_popup": .bool(action.hasPopup)])
        }
        return .object([
            "manages": .bool(store.supportsManagement),
            "extensions": .array(extensions),
            "commands": .array(commands),
            "actions": .array(actions),
        ])
    }
}
