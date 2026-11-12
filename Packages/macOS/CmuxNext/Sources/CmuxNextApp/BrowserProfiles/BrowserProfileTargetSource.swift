import CmuxNextActions
import CmuxNextBrowser
import CmuxNextBookmarks
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextPalette

/// Lists browser profiles for `browser-profile` arguments (New Tab with
/// Browser Profile…, Move Tab to Browser Profile…): every profile in
/// order, each with its icon or first letter. Other kinds fall through.
final class BrowserProfileTargetSource: PaletteTargetSource {
    private unowned let services: AppServices
    private let next: any PaletteTargetSource

    init(services: AppServices, next: any PaletteTargetSource) {
        self.services = services
        self.next = next
    }

    func targets(of kind: ActionTargetKind) -> [PaletteTargetOption] {
        if kind == .bookmark { return bookmarks(source: nil) }
        guard kind == .browserProfile else { return next.targets(of: kind) }
        return services.browserProfiles.ordered.map { record in
            PaletteTargetOption(id: record.id, title: record.name, subtitle: record.icon, symbol: record.isDefault ? "person.crop.circle" : "person.crop.circle.fill")
        }
    }

    /// An action's catalog narrows this profile's nodes to URLs or folders.
    func bookmarks(source: String?) -> [PaletteTargetOption] {
        let profile = BookmarkResolver(services: services).profile(ActionInvocation())
        return services.bookmarks.tree(profile).ordered.filter {
            source == "bookmarkFolders" ? $0.isFolder : source == "bookmarks" ? !$0.isFolder : true
        }.map { PaletteTargetOption(id: $0.id, title: $0.displayTitle, subtitle: $0.url?.host, symbol: $0.isFolder ? "folder" : "star") }
    }

    /// Descriptions belong to kinds `next` lists.
    func currentDescription(of target: ActionTargetRef) -> String? {
        next.currentDescription(of: target)
    }

    /// Makes a profile from a typed name no profile has, with New Browser Profile's defaults.
    static func creator(services: AppServices) -> PaletteTargetCreator {
        PaletteTargetCreator(title: BrowserProfileAppStrings.createNamed, symbol: "person.crop.circle.badge.plus") { [weak services] name in
            guard let profiles = services?.browserProfiles else { throw CancellationError() }
            let color = GroupColor.automatic(used: Set(profiles.ordered.compactMap(\.color)))?.rawValue
            do {
                return try await profiles.createProfile(name: name, color: color, icon: nil)
            } catch let error as BrowserProfileBookError {
                throw ActionFailure.invalidTarget(BrowserProfileAppStrings.message(error))
            }
        }
    }
}
