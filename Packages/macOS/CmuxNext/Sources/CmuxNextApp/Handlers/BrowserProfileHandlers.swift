import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDesign

/// Browser profile actions (plans/cmux-next/data-model.md 5 and 7): create,
/// edit and delete profiles; open tabs, windows and workspaces in one; set
/// workspace and room defaults; move or duplicate a tab into another one.
/// Records are this Mac's (`BrowserProfileService`); room defaults live in
/// the home daemon's personal state and need `profiles-v1`.
enum BrowserProfileHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let profiles = context.services.browserProfiles
        func bind(_ id: ActionID, _ run: @escaping @MainActor (ActionInvocation) throws -> Void) {
            registry.bind(id, run: { invocation in
                do { try run(invocation) } catch let error as BrowserProfileBookError {
                    throw ActionFailure.invalidTarget(BrowserProfileAppStrings.message(error))
                }
            })
        }
        bind("browserProfile.new") { try create(invocation: $0, profiles) }
        bind("browserProfile.rename") { invocation in
            let record = try context.browserProfile(invocation)
            let id = record.id
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                try profiles.rename(id, to: name)
            } else if !context.services.registry.ask("browserProfile.rename", invocation, ActionArgumentAsk(argument: "name", initialText: record.name)) {
                throw ActionFailure.invalidTarget(BrowserProfileAppStrings.invalidName)
            }
        }
        bind("browserProfile.setColor") { invocation in
            let id = try context.browserProfile(invocation).id
            let color = invocation["color"]?.stringValue
            try profiles.setColor(id, color)
        }
        bind("browserProfile.clearColor") { invocation in
            let id = try context.browserProfile(invocation).id
            try profiles.setColor(id, nil)
        }
        bind("browserProfile.setIcon") { invocation in
            let record = try context.browserProfile(invocation)
            let id = record.id
            let history = IconHistory.browserProfile(context)
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                try history.change(id, from: record.icon, to: icon, origin: invocation.origin)
            } else if let anchor = context.services.iconPicker.activeWindowAnchor() {
                // Browser profiles live in the local daemon, which stores their image and SVG icons.
                let assets = IconAssetStore.owner(context.services.machines.local)
                context.services.iconPicker.pick(current: record.icon, target: "browserProfile:\(id)", at: anchor,
                                                 assets: assets) { result in
                    // The record is a value: read the icon the profile shows when the pick lands.
                    let current = profiles.record(id)?.icon
                    switch result {
                    case .set(let icon): try? history.change(id, from: current, to: icon, origin: .user)
                    case .clear: try? history.change(id, from: current, to: nil, origin: .user)
                    case .cancel: break
                    }
                }
            } else {
                throw ActionFailure.invalidTarget(BrowserProfileAppStrings.invalidIcon)
            }
        }
        bind("browserProfile.clearIcon") { invocation in
            let record = try context.browserProfile(invocation)
            try IconHistory.browserProfile(context).change(record.id, from: record.icon, to: nil, origin: invocation.origin)
        }
        bind("browserProfile.delete") { invocation in
            let record = try context.browserProfile(invocation)
            guard !record.isDefault else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.defaultCannotBeDeleted) }
            try profiles.delete(record.id)
        }
        bindDaemonVerbs(into: registry, context: context)
        BrowserProfileOpenHandlers.bind(bind, context: context)
        BrowsingDataClear.bind(bind, context: context)
    }

    /// `cmux browser profile move|proxy set|proxy clear` from the palette; the daemon checks a proxy as it does the CLI's.
    private static func bindDaemonVerbs(into registry: ActionRegistry, context: AppActionContext) {
        let profiles = context.services.browserProfiles
        func bind(_ id: ActionID, _ edit: @escaping @MainActor (String, ActionInvocation) throws -> Void) {
            registry.bindEffect(id, requires: nil, effect: { invocation in
                do { try edit(context.browserProfile(invocation).id, invocation); return .done } catch let error as BrowserProfileBookError {
                    throw ActionFailure.invalidTarget(BrowserProfileAppStrings.message(error))
                }
            })
        }
        bind("browserProfile.move") { id, invocation in
            guard let position = invocation["index"]?.intValue else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.positionRequired) }
            try profiles.move(id, to: min(position - 1, context.services.machines.local.store.personal.browserProfiles.count - 1))
        }
        bind("browserProfile.setProxy") { id, invocation in
            guard let scheme = invocation["scheme"]?.stringValue, let host = invocation["host"]?.stringValue,
                  let port = invocation["port"]?.intValue else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.invalidProxy) }
            try profiles.setProxy(id, BrowserProfileSnapshot.Proxy(scheme: scheme, host: host.trimmingCharacters(in: .whitespaces), port: port))
        }
        bind("browserProfile.clearProxy") { id, _ in try profiles.setProxy(id, nil) }
    }

    /// A new profile: the given name, color and icon, else "Profile N" and
    /// the first color no other profile uses.
    private static func create(invocation: ActionInvocation, _ profiles: BrowserProfileService) throws {
        let (name, color) = profiles.newProfileDefaults(name: invocation["name"]?.stringValue, color: invocation["color"]?.stringValue)
        let icon = invocation["icon"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        try profiles.createProfileNow(name: name, color: color, icon: icon)
    }
}

/// Target resolution for browser profile handlers.
extension AppActionContext {
    /// The profile an invocation names (a `browser-profile` target, else the
    /// `browserProfile` argument as id or name), else the focused browser
    /// tab's, else `default`.
    func browserProfile(_ invocation: ActionInvocation) throws -> BrowserProfileRecord {
        if let record = try explicitBrowserProfile(invocation) { return record }
        let profiles = services.browserProfiles
        if let (tab, _) = focusedBrowserTab(), let record = profiles.record(profiles.profileID(ofTab: tab)) { return record }
        return profiles.record(BrowserProfileRecord.defaultID) ?? BrowserProfileRecord(id: BrowserProfileRecord.defaultID, name: BrowserProfileStrings.defaultName)
    }

    /// The profile an invocation names, refusing when it names none.
    func requiredBrowserProfile(_ invocation: ActionInvocation) throws -> BrowserProfileRecord {
        guard let record = try explicitBrowserProfile(invocation) else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.profileRequired) }
        return record
    }

    /// The profile an invocation names (its target, or its `browserProfile`
    /// argument by id or name), nil when it names none; an unknown one throws.
    func explicitBrowserProfile(_ invocation: ActionInvocation) throws -> BrowserProfileRecord? {
        let text: String?
        if let target = invocation.target, target.kind == .browserProfile {
            text = target.id
        } else if let value = invocation["browserProfile"] {
            text = value.targetValue?.id ?? value.stringValue
        } else {
            return nil
        }
        guard let text, !text.isEmpty else { return nil }
        let profiles = services.browserProfiles
        if let record = profiles.record(text) { return record }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if let record = profiles.ordered.first(where: { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == folded }) {
            return record
        }
        throw ActionFailure.invalidTarget(BrowserProfileAppStrings.noProfile(text))
    }

    /// The focused pane's selected tab when it is a browser tab.
    func focusedBrowserTab() -> (TabModel, PaneModel)? {
        guard let pane = services.windows.active?.focusedPane, let id = pane.stripModel.selectedID,
              let tab = pane.tab(id), tab.kind == .browser else { return nil }
        return (tab, pane.pane)
    }
}
