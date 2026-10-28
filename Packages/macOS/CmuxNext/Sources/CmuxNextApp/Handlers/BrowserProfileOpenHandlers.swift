import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Browser profile actions that open pages or set defaults: New Tab, New
/// Window and New Workspace with a profile, Open Link in a profile, the
/// workspace and room defaults, Move and Duplicate Tab into a profile, and
/// Manage Extensions, Passwords and Addresses of a profile (data-model.md 5
/// and 7): Chromium's own pages in a Chromium tab of that profile.
enum BrowserProfileOpenHandlers {
    typealias Bind = (ActionID, @escaping @MainActor (ActionInvocation) throws -> Void) -> Void

    static func bind(_ bind: Bind, context: AppActionContext) {
        let profiles = context.services.browserProfiles
        bind("browserProfile.newTab") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            guard let pane = context.paneController(invocation) else { return }
            let url = invocation["url"]?.stringValue.flatMap { $0.isEmpty ? nil : URL(string: $0) }
            pane.newBrowserTab(url: url, profile: record.id)
        }
        bind("browserProfile.openLink") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            guard let text = invocation["url"]?.stringValue, let url = URL(string: text), url.scheme != nil else {
                throw ActionFailure.invalidTarget(BrowserProfileAppStrings.urlRequired)
            }
            guard let pane = context.paneController(invocation) else { return }
            pane.newBrowserTab(url: url, profile: record.id)
        }
        bind("browserProfile.newWindow") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            let windows = context.services.windows
            let windowID = UUID().uuidString.lowercased()
            var spawn = WorkspaceSpawn()
            spawn.browserProfile = record.id
            Task { _ = try? await windows.createWorkspace(spawn, into: windowID) }
        }
        bind("browserProfile.newWorkspace") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            let windows = context.services.windows
            let target = windows.targetWindow(preferring: windows.active?.state.id)
            var spawn = WorkspaceSpawn()
            spawn.browserProfile = record.id
            Task { _ = try? await windows.createWorkspace(spawn, into: target) }
        }
        bind("browserProfile.setWorkspaceDefault") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            let (workspace, _) = try context.workspace(invocation)
            try profiles.setWorkspaceDefault(record.id, for: workspace.id)
        }
        bind("browserProfile.clearWorkspaceDefault") { invocation in
            let (workspace, _) = try context.workspace(invocation)
            try profiles.setWorkspaceDefault(nil, for: workspace.id)
        }
        bind("browserProfile.setSpaceDefault") { invocation in
            try context.requireRooms()
            let record = try context.requiredBrowserProfile(invocation)
            let room = try context.room(invocation)
            let key = BrowserProfileKey(rawValue: record.id)
            RoomHandlers.update(room.id, context) { try await $0.updateProfile($1, browserProfileID: .set(key)) }
        }
        bind("browserProfile.clearSpaceDefault") { invocation in
            try context.requireRooms()
            let room = try context.room(invocation)
            RoomHandlers.update(room.id, context) { try await $0.updateProfile($1, browserProfileID: .clear) }
        }
        bind("browserProfile.moveTab") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            guard let (tab, pane) = context.daemonTab(invocation) else { return }
            try profiles.requireMovable(tab, to: record.id, allowSame: false)
            let notice = BrowserProfileAppStrings.movedNotice(to: record.name, from: profiles.displayName(profiles.profileID(ofTab: tab)))
            profiles.move(tab, in: pane, to: record.id, notice: notice)
        }
        bind("browserProfile.duplicateTab") { invocation in
            let record = try context.requiredBrowserProfile(invocation)
            guard let (tab, pane) = context.daemonTab(invocation) else { return }
            try profiles.requireMovable(tab, to: record.id, allowSame: true)
            profiles.reopen(tab, in: pane, profile: record.id, closingOriginal: false,
                            notice: BrowserProfileAppStrings.duplicatedNotice(record.name))
        }
        bind("browserProfile.manageExtensions") { invocation in
            // Each profile is its own Chromium profile with its own
            // extensions; chrome://extensions in a tab of it manages them.
            let record = try context.requiredBrowserProfile(invocation)
            guard let pane = context.paneController(invocation) else { return }
            pane.newBrowserTab(url: URL.browserExtensionManagement, engine: BrowserEngineTag.cef.rawValue, profile: record.id)
        }
        // Each profile's passwords and contact info live in its own Chromium
        // profile; Chromium's own pages in a tab of it manage them.
        bind("browserProfile.managePasswords") { invocation in
            try openAutofillPage(.passwords, invocation, context: context)
        }
        bind("browserProfile.manageAddresses") { invocation in
            try openAutofillPage(.addresses, invocation, context: context)
        }
    }

    /// Opens Chromium's `page` in a Chromium tab of the invocation's browser
    /// profile; with none named, the profile a new tab of the pane gets.
    static func openAutofillPage(_ page: ChromiumAutofillPage, _ invocation: ActionInvocation, context: AppActionContext) throws {
        let record = try context.explicitBrowserProfile(invocation)
        guard let pane = context.paneController(invocation) else { return }
        pane.newBrowserTab(url: page.url, engine: BrowserEngineTag.cef.rawValue, profile: record?.id)
    }
}
