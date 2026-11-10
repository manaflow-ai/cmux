import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// Set and remove a bookmark folder's icon (`bookmark-icon-v1`, cx-qno.11.3):
/// the shared icon string, the same rule as workspace group icons. An icon
/// argument (CLI, MCP, scripts) sets it; without one (the bar's and the
/// manager page's right-click menus) the shared icon picker opens beside
/// the folder and its pick takes the same path. Every change goes through
/// `IconHistory`, so a user's change offers an undo. Bookmarks live in the
/// home daemon, which takes the change and stores an image or SVG pick.
enum BookmarkIconHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let services = ctx.services, resolver = BookmarkResolver(services: services)
        let capability = DaemonCapability.bookmarkIcon.rawValue
        registry.bind("bookmark.setIcon", requires: capability, daemon: services.machines.local, run: { invocation in
            let icon = try iconArgument(invocation)
            withFolder(invocation, resolver) { folder, profile in
                let history = IconHistory.bookmark(ctx, profile: profile)
                if let icon { return try history.change(folder.id, from: folder.icon, to: icon, origin: invocation.origin) }
                guard let anchor = services.iconPicker.anchor(bookmark: folder.id) else {
                    throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
                }
                services.iconPicker.pick(current: folder.icon, target: "bookmark:\(folder.id)", at: anchor,
                                         assets: IconAssetStore.owner(services.bookmarks.iconOwner)) { result in
                    switch result {
                    case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true):
                        try? history.change(folder.id, from: folder.icon, to: icon, origin: .user)
                    case .clear: try? history.change(folder.id, from: folder.icon, to: nil, origin: .user)
                    case .set, .cancel: break
                    }
                }
            }
        })
        registry.bind("bookmark.clearIcon", requires: capability, daemon: services.machines.local, run: { invocation in
            withFolder(invocation, resolver) { folder, profile in
                try IconHistory.bookmark(ctx, profile: profile).change(folder.id, from: folder.icon, to: nil, origin: invocation.origin)
            }
        })
        // A bookmark's menu leaves both out; a folder's leaves Remove Icon out while it has none
        // (quiet: building a menu never refuses). The bar that opened the menu said what its row is.
        ActionTargetVisibility.hide("bookmark.setIcon", in: registry) { menuFolder($0, services) == nil }
        ActionTargetVisibility.hide("bookmark.clearIcon", in: registry) { (menuFolder($0, services)?.icon ?? "").isEmpty }
    }

    /// The folder row a bar's context menu opened for, when the invocation targets it.
    private static func menuFolder(_ invocation: ActionInvocation, _ services: AppServices) -> BookmarkService.MenuTarget? {
        guard let target = invocation.target, target.kind == .bookmark, let menu = services.bookmarks.menuTarget,
              menu.id == target.id, menu.isFolder else { return nil }
        return menu
    }

    /// Runs `body` on the folder an invocation names. The bar's menu row acts at once on what the
    /// bar drew (the picker opens beside it); a CLI or MCP name (a folder id or title ahead of the
    /// bookmark matching the shared resolver uses) resolves on the daemon's tree first. A URL
    /// bookmark is refused: only a folder has an icon.
    static func withFolder(_ invocation: ActionInvocation, _ resolver: BookmarkResolver,
                           _ body: @escaping @MainActor (_ folder: (id: String, icon: String?), _ profile: String) throws -> Void) {
        if let menu = menuFolder(invocation, resolver.services) {
            do { return try body((menu.id, menu.icon), menu.profile) } catch let failure as ActionFailure {
                return resolver.services.registry.refuse(failure.message)
            } catch {
                return resolver.services.registry.refuse(BookmarkAppStrings.failure(error))
            }
        }
        resolver.withResolved(invocation, bookmark: true, foldersFirst: true) { resolved, profile in
            guard let node = resolved.bookmark else { throw ActionFailure(message: BookmarkAppStrings.notFound) }
            guard node.isFolder else { throw ActionFailure(message: BookmarkAppStrings.notFolder) }
            try body((node.id, node.icon), profile)
        }
    }

    /// The `icon` argument: trimmed, nil when absent or empty (the picker
    /// opens), refused unless it is an emoji, an SF Symbol this Mac draws, or
    /// a stored image or SVG asset.
    static func iconArgument(_ invocation: ActionInvocation) throws -> String? {
        guard let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else { return nil }
        guard WorkspaceIconValue.isValid(icon, assets: true) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon) }
        return icon
    }
}

extension IconHistory {
    /// A bookmark folder of `profile` (the home daemon's bookmarks). The change goes to the daemon;
    /// a refusal is said in the refusal toast.
    static func bookmark(_ ctx: AppActionContext, profile: String) -> Self {
        inActiveWindow(ctx) { id, update in
            let bookmarks = ctx.services.bookmarks
            guard bookmarks.supportsFolderIcons else {
                throw ActionFailure(message: bookmarks.iconOwner.missingCapabilityMessage(DaemonCapability.bookmarkIcon.rawValue))
            }
            let icon: BookmarkRoutedClient.JSONValue? = switch update {
            case .unchanged: nil
            case .clear: .null
            case .set(let value): .string(value)
            }
            guard let icon else { return false }
            bookmarks.run([.update(id: id, icon: icon)])
            return true
        }
    }
}
