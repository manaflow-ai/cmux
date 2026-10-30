import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextDaemon
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
            let node = try folder(invocation, resolver)
            let history = IconHistory.bookmark(ctx), id = node.id, profile = resolver.profile(invocation)
            if let icon = try iconArgument(invocation) {
                return try history.change(id, from: node.icon, to: icon, origin: invocation.origin)
            }
            guard let anchor = services.iconPicker.anchor(bookmark: id) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            services.iconPicker.pick(current: node.icon, target: "bookmark:\(id)", at: anchor,
                                     assets: IconAssetStore.owner(services.bookmarks.iconOwner)) { result in
                // The node is a value: read the icon the folder shows when the pick lands.
                let current = services.bookmarks.tree(profile).node(id)?.icon
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true):
                    try? history.change(id, from: current, to: icon, origin: .user)
                case .clear: try? history.change(id, from: current, to: nil, origin: .user)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("bookmark.clearIcon", requires: capability, daemon: services.machines.local, run: { invocation in
            let node = try folder(invocation, resolver)
            try IconHistory.bookmark(ctx).change(node.id, from: node.icon, to: nil, origin: invocation.origin)
        })
        // A bookmark's menu leaves both out; a folder's leaves Remove Icon out
        // while it has none (quiet: building a menu never refuses).
        ActionTargetVisibility.hide("bookmark.setIcon", in: registry) { quietFolder($0, resolver) == nil }
        ActionTargetVisibility.hide("bookmark.clearIcon", in: registry) { (quietFolder($0, resolver)?.icon ?? "").isEmpty }
    }

    /// The folder an invocation names: a folder id or title (first in tree order) ahead of the
    /// bookmark matching the shared resolver uses, else that; refuses a URL bookmark (only a
    /// folder has an icon).
    static func folder(_ invocation: ActionInvocation, _ resolver: BookmarkResolver) throws -> BookmarkNode {
        let profile = resolver.profile(invocation)
        if invocation.target?.kind != .bookmark,
           let text = invocation["bookmark"]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            let tree = resolver.services.bookmarks.tree(profile), folded = text.lowercased()
            if let folder = tree.node(text) ?? tree.ordered.first(where: { $0.isFolder && $0.title.lowercased() == folded }),
               folder.isFolder {
                return folder
            }
        }
        let node = try resolver.node(invocation, profile: profile)
        guard node.isFolder else { throw ActionFailure(message: BookmarkAppStrings.notFolder) }
        return node
    }

    private static func quietFolder(_ invocation: ActionInvocation, _ resolver: BookmarkResolver) -> BookmarkNode? {
        try? folder(invocation, resolver)
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
    /// A bookmark folder, in whichever browser profile's tree holds it (the
    /// home daemon's bookmarks).
    static func bookmark(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            let bookmarks = ctx.services.bookmarks
            guard let profile = bookmarks.trees.first(where: { $0.value.node(id)?.isFolder == true })?.key else { return false }
            guard bookmarks.supportsFolderIcons else {
                throw ActionFailure(message: bookmarks.iconOwner.missingCapabilityMessage(DaemonCapability.bookmarkIcon.rawValue))
            }
            let change: BookmarkFieldChange<String> = switch update {
            case .unchanged: .unchanged
            case .clear: .clear
            case .set(let icon): .set(icon)
            }
            do { try bookmarks.apply(.update(id: id, icon: change), profile: profile) } catch {
                throw ActionFailure(message: BookmarkAppStrings.failure(error))
            }
            return true
        }
    }
}
