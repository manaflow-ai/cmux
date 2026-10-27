import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation

/// Bookmark actions (plans/cmux-next/bookmarks.md section 3): one handler
/// per verb for the palette, menus, the bar's context menu, shortcuts and
/// `cmux bookmark …`.
enum BookmarkHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        let resolver = BookmarkResolver(services: services)
        registry.bind("bookmark.addPage", run: { invocation in
            guard let key = resolver.browserTabKey(invocation) else { throw ActionFailure(message: BookmarkAppStrings.noBrowserTab) }
            services.bookmarks.starPressed(tab: key, anchor: nil)
        })
        registry.bind("bookmark.addAllTabs", run: { invocation in try addAllTabs(invocation, context, resolver) })
        registry.bind("bookmark.add", run: { invocation in
            let profile = resolver.profile(invocation)
            guard let url = invocation["url"]?.stringValue.flatMap(BookmarkURL.parse) else {
                throw ActionFailure(message: BookmarkAppStrings.invalidURL)
            }
            let folder = try resolver.folder(invocation, profile: profile)
            let title = invocation["title"]?.stringValue ?? ""
            try apply(services, .create(.bookmark(title, url: url, in: folder), index: nil), profile)
        })
        registry.bind("bookmark.newFolder", run: { invocation in
            let profile = resolver.profile(invocation)
            let folder = try resolver.folder(invocation, profile: profile)
            let name = invocation["name"]?.stringValue ?? BookmarkStrings.newFolder
            try apply(services, .create(.folder(name, in: folder), index: nil), profile)
        })
        services.palettes.sources.actionPages["bookmark.open"] = { [weak services] in services.map(BookmarkPalettePages.open) }
        registry.bind("bookmark.open", run: { invocation in
            guard invocation.target != nil || invocation["bookmark"]?.stringValue?.isEmpty == false else {
                return services.palette.show(page: BookmarkPalettePages.open(services), relativeTo: context.activeWindow?.window)
            }
            try open(invocation, resolver, services, .currentTab)
        })
        registry.bind("bookmark.openInNewTab", run: { invocation in try open(invocation, resolver, services, .newTab) })
        registry.bind("bookmark.openInBackgroundTab", run: { invocation in try open(invocation, resolver, services, .backgroundTab) })
        registry.bind("bookmark.openAll", run: { invocation in
            let profile = resolver.profile(invocation)
            let node = try resolver.node(invocation, profile: profile)
            BookmarkOpener(services: services).openAll(in: node.isFolder ? node.id : node.parent, profile: profile)
        })
        registry.bind("bookmark.edit", run: { invocation in try edit(invocation, resolver, services) })
        registry.bind("bookmark.move", run: { invocation in
            let profile = resolver.profile(invocation)
            let node = try resolver.node(invocation, profile: profile)
            let folder = try resolver.folder(invocation, profile: profile)
            let index = invocation["index"]?.intValue ?? services.bookmarks.tree(profile).children(of: folder).count
            try apply(services, .move(id: node.id, parent: folder, index: index), profile)
        })
        registry.bind("bookmark.copyLink", run: { invocation in
            let node = try resolver.node(invocation, profile: resolver.profile(invocation))
            guard let url = node.url else { throw ActionFailure(message: BookmarkAppStrings.folderHasNoLink) }
            context.copy(url.absoluteString)
        })
        // A folder's menu leaves Copy Bookmark Link out (quiet: building a menu never refuses).
        ActionTargetVisibility.hide("bookmark.copyLink", in: registry) { invocation in
            (try? resolver.node(invocation, profile: resolver.profile(invocation)))?.isFolder == true
        }
        registry.bind("bookmark.remove", run: { invocation in
            let profile = resolver.profile(invocation)
            let node = try resolver.node(invocation, profile: profile)
            try apply(services, .delete(id: node.id), profile)
        })
        registry.bind("bookmark.toggleBar", run: { _ in
            let shown = !services.bookmarks.isBarShown
            services.bookmarks.setBarShown(shown)
            guard let settings = services.settings else { return }
            // The write is awaited off the action's turn; its failure is one task of the run's completion.
            services.registry.trackWork(owner: "BookmarkHandlers.toggleBar", on: services.mainWork) {
                try await settings.setShowBookmarksBar(shown)
            } then: { result in
                guard case .failure(let error) = result else { return nil }
                return ActionWorkFailure(String(describing: error))
            }
        })
        registry.bind("bookmark.manager", run: { _ in services.bookmarkPages.open() })
        registry.bind("bookmark.import", run: { invocation in
            let profile = resolver.profile(invocation)
            guard let path = invocation["path"]?.stringValue, !path.isEmpty else {
                return BookmarkFiles(services: services).chooseImport(profile: profile)
            }
            BookmarkFiles(services: services).importFile(URL(filePath: (path as NSString).expandingTildeInPath), profile: profile)
        })
        registry.bind("bookmark.importFromBrowser", run: { invocation in
            let profile = resolver.profile(invocation)
            let window = context.activeWindow?.window
            guard let browser = invocation["browser"]?.stringValue, !browser.isEmpty else {
                return BookmarkBrowserImport(services: services).choose(profile: profile, window: window)
            }
            // CLI and agents (bookmarks are not secrets, I5): name the browser, optionally the profile.
            let source = invocation["source"]?.stringValue
            let work = services.work, priority = invocation.completionPriority
            // The browsers' folders and the picked profiles' bookmarks are blocking file and SQLite reads, on the
            // files lane; the import (one undo step) and its summary are one task of the run's completion.
            registry.trackWork(owner: "BookmarkHandlers.importFromBrowser", on: services.mainWork) { () -> [BookmarkBrowserImport.Read]? in
                try await work.run(priority, mayBlock: .files) {
                    let found = BookmarkBrowserImport.sources(environment: BookmarkBrowserImport.liveEnvironment())
                    let picked = BookmarkBrowserImport.match(found, browser: browser, source: source)
                    return picked.isEmpty ? nil : BookmarkBrowserImport.read(picked)
                }
            } then: { result in
                switch result {
                case .success(let reads?):
                    let importer = BookmarkBrowserImport(services: services)
                    let outcome = importer.apply(reads, target: profile)
                    importer.announce(outcome, in: window)
                    return outcome.failed.isEmpty ? nil : ActionWorkFailure(BookmarkAppStrings.importFailed(outcome.failed.joined(separator: ", ")))
                case .success(nil):
                    return ActionWorkFailure(BookmarkAppStrings.importUnknownSource([browser, source].compactMap { $0 }.joined(separator: " ")))
                case .failure(let error):
                    return ActionWorkFailure(String(describing: error))
                }
            }
        })
        registry.bind("bookmark.export", run: { invocation in
            let profile = resolver.profile(invocation)
            guard let path = invocation["path"]?.stringValue, !path.isEmpty else {
                return BookmarkFiles(services: services).chooseExport(profile: profile)
            }
            BookmarkFiles(services: services).exportFile(URL(filePath: (path as NSString).expandingTildeInPath), profile: profile)
        })
    }

    private static func apply(_ services: AppServices, _ operation: BookmarkOperation, _ profile: String) throws {
        do { try services.bookmarks.apply(operation, profile: profile) } catch {
            throw ActionFailure(message: BookmarkAppStrings.failure(error))
        }
    }

    private static func open(_ invocation: ActionInvocation, _ resolver: BookmarkResolver, _ services: AppServices,
                             _ disposition: BookmarkOpenDisposition) throws {
        let profile = resolver.profile(invocation)
        let node = try resolver.node(invocation, profile: profile)
        // Agents never open Chromium's own pages, also not through a bookmark (AgentURLPolicy).
        if invocation.origin != .user {
            let urls = node.isFolder ? services.bookmarks.tree(profile).children(of: node.id).compactMap(\.url) : [node.url].compactMap { $0 }
            if urls.contains(where: { AgentURLPolicy.refuses($0) }) { throw ActionFailure(message: MiscHandlerStrings.agentChromiumPage) }
        }
        guard !node.isFolder else { return BookmarkOpener(services: services).openAll(in: node.id, profile: profile) }
        BookmarkOpener(services: services).open(node, profile: profile, disposition: disposition)
    }

    /// With a name or URL argument the edit applies at once (CLI); else the
    /// edit bubble opens on the focused tab's star, or the manager page.
    private static func edit(_ invocation: ActionInvocation, _ resolver: BookmarkResolver, _ services: AppServices) throws {
        let profile = resolver.profile(invocation)
        let node = try resolver.node(invocation, profile: profile)
        let title = invocation["title"]?.stringValue
        let url = try invocation["url"]?.stringValue.map { text in
            guard let url = BookmarkURL.parse(text) else { throw ActionFailure(message: BookmarkAppStrings.invalidURL) }
            return url
        }
        if title != nil || url != nil { return try apply(services, .update(id: node.id, title: title, url: url), profile) }
        services.bookmarkPages.open(selecting: node.id)
    }

    /// Every web page tab of the window into a new folder (Bookmark All Tabs), as Chrome
    /// bookmarks a window's tabs: every pane of every screen it shows, in layout order,
    /// session-local pages included. A tab keeps its browser profile, so each profile gets
    /// its own folder; an explicit `profile` takes only that profile's tabs.
    private static func addAllTabs(_ invocation: ActionInvocation, _ context: AppActionContext, _ resolver: BookmarkResolver) throws {
        let services = context.services
        guard let pane = context.paneController(invocation) else { return }
        let only = invocation["profile"] == nil ? nil : resolver.profile(invocation)
        var folders: [(profile: String, pages: [BookmarkDraft])] = []
        for (id, model) in pane.workspace?.tabsInLayoutOrder() ?? pane.pane.tabs.map({ (id: $0.id, model: Optional($0)) }) {
            let page = services.cache.existingBrowser(id)?.tab
            guard model.map({ $0.kind == .browser }) ?? (page != nil),
                  let url = page?.state.url ?? model?.url.flatMap(URL.init(string:)), BookmarkService.canBookmark(url) else { continue }
            let profile = services.bookmarks.profile(ofTab: id)
            guard only.map({ $0 == profile }) ?? true else { continue }
            let draft = BookmarkDraft.bookmark(page?.state.title ?? model?.title ?? url.absoluteString, url)
            if let index = folders.firstIndex(where: { $0.profile == profile }) { folders[index].pages.append(draft) } else { folders.append((profile, [draft])) }
        }
        guard !folders.isEmpty else { throw ActionFailure(message: BookmarkAppStrings.noTabs) }
        let name = invocation["name"]?.stringValue ?? BookmarkAppStrings.allTabsFolder
        for folder in folders {
            try apply(services, .importDrafts(parent: services.bookmarks.defaultFolder(profile: folder.profile), index: nil, sourceKey: nil,
                                              replace: false, drafts: [.folder(name, folder.pages)]), folder.profile)
        }
    }
}
