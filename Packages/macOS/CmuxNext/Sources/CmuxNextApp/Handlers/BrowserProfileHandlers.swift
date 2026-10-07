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
            } else if let window = context.activeWindow?.window {
                RenamePrompt.run(title: BrowserProfileAppStrings.renameTitle, initial: record.name, in: window) { name in
                    try? profiles.rename(id, to: name)
                }
            } else {
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
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                try profiles.setIcon(id, icon)
            } else if let anchor = context.services.iconPicker.activeWindowAnchor() {
                context.services.iconPicker.pick(current: record.icon, target: "browserProfile:\(id)", at: anchor) { result in
                    switch result {
                    case .set(let icon): try? profiles.setIcon(id, icon)
                    case .clear: try? profiles.setIcon(id, nil)
                    case .cancel: break
                    }
                }
            } else {
                throw ActionFailure.invalidTarget(BrowserProfileAppStrings.invalidIcon)
            }
        }
        bind("browserProfile.clearIcon") { invocation in
            let id = try context.browserProfile(invocation).id
            try profiles.setIcon(id, nil)
        }
        bind("browserProfile.delete") { invocation in
            let record = try context.browserProfile(invocation)
            guard !record.isDefault else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.defaultCannotBeDeleted) }
            try profiles.delete(record.id)
        }
        BrowserProfileOpenHandlers.bind(bind, context: context)
    }

    /// A new profile: the given name, color and icon, else "Profile N" and
    /// the first color no other profile uses.
    private static func create(invocation: ActionInvocation, _ profiles: BrowserProfileService) throws {
        let name = invocation["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? BrowserProfileAppStrings.defaultName(profiles.ordered.count + 1)
        let used = Set(profiles.ordered.compactMap(\.color))
        let color = invocation["color"]?.stringValue
            ?? GroupColor.automatic(used: used)?.rawValue
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

    private func explicitBrowserProfile(_ invocation: ActionInvocation) throws -> BrowserProfileRecord? {
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
