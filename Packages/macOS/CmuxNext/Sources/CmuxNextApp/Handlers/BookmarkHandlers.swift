import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation

/// Bookmark actions (plans/cmux-next/bookmarks.md section 3): one handler
/// per verb for the palette, menus, the bar's context menu, shortcuts and
/// `cmux bookmark …`. Each names its bookmark and folder on the home daemon's tree
/// (``BookmarkResolver``) and edits it there, as tracked work the CLI and MCP wait for (else refused).
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
            guard invocation["url"]?.stringValue?.isEmpty == false else { throw ActionFailure(message: BookmarkAppStrings.invalidURL) }
            let title = invocation["title"]?.stringValue ?? ""
            resolver.withResolved(invocation, folder: true) { resolved, profile in
                guard let url = resolved.url, let folder = resolved.folder else { throw ActionFailure(message: BookmarkAppStrings.invalidURL) }
                try await apply(services, [.create(id: nil, profile: profile, parent: folder, folder: false, title: title, url: url)])
                services.bookmarks.lastFolder[profile] = folder
            }
        })
        registry.bind("bookmark.newFolder", run: { invocation in
            let name = invocation["name"]?.stringValue ?? BookmarkStrings.newFolder
            resolver.withResolved(invocation, folder: true) { resolved, profile in
                guard let folder = resolved.folder else { throw ActionFailure(message: BookmarkAppStrings.notFolder) }
                try await apply(services, [.create(id: nil, profile: profile, parent: folder, folder: true, title: name)])
            }
        })
        services.palette.sources.actionPages["bookmark.open"] = { [weak services] in services.map(BookmarkPalettePages.open) }
        registry.bind("bookmark.open", run: { invocation in
            guard invocation.target != nil || invocation["bookmark"]?.stringValue?.isEmpty == false else {
                return services.palette.show(page: BookmarkPalettePages.open(services), relativeTo: context.activeWindow?.window)
            }
            open(invocation, resolver, services, .currentTab)
        })
        registry.bind("bookmark.openInNewTab", run: { invocation in open(invocation, resolver, services, .newTab) })
        registry.bind("bookmark.openInBackgroundTab", run: { invocation in open(invocation, resolver, services, .backgroundTab) })
        registry.bind("bookmark.openAll", run: { invocation in
            resolver.withNode(invocation) { node, profile in
                try await BookmarkOpener(services: services).openAll(in: node.isFolder ? node.id : node.parent, profile: profile)
            }
        })
        registry.bind("bookmark.edit", run: { invocation in edit(invocation, resolver, services) })
        registry.bind("bookmark.move", run: { invocation in
            let index = invocation["index"]?.intValue
            resolver.withResolved(invocation, bookmark: true, folder: true) { resolved, _ in
                guard let node = resolved.bookmark, let folder = resolved.folder else { throw ActionFailure(message: BookmarkAppStrings.notFound) }
                // No index: the end of the folder (the daemon clamps a large one).
                try await apply(services, [.move(id: node.id, parent: folder, index: index ?? Int(Int32.max))])
            }
        })
        registry.bind("bookmark.copyLink", run: { invocation in
            resolver.withNode(invocation) { node, _ in
                guard let url = node.url else { throw ActionFailure(message: BookmarkAppStrings.folderHasNoLink) }
                context.copy(url.absoluteString)
            }
        })
        // A folder's menu leaves Copy Bookmark Link out (quiet: building a menu never refuses). The
        // bar that opened the menu said what its row is.
        ActionTargetVisibility.hide("bookmark.copyLink", in: registry) { invocation in
            guard let target = invocation.target, let menu = services.bookmarks.menuTarget, menu.id == target.id else { return false }
            return menu.isFolder
        }
        registry.bind("bookmark.remove", run: { invocation in
            resolver.withNode(invocation) { node, _ in try await apply(services, [.delete(id: node.id)]) }
        })
        registry.bind("bookmark.toggleBar", run: { _ in
            let shown = !services.bookmarks.isBarShown
            services.bookmarks.setBarShown(shown)
            guard let settings = services.settings else { return }
            services.registry.trackOrRefuse(Task { @MainActor in
                do { try await settings.setShowBookmarksBar(shown) } catch { return ActionWorkFailure(String(describing: error)) }
                return nil
            })
        })
        ActionTargetTitles.set("bookmark.toggleBar", in: registry) { _ in services.bookmarks.isBarShown ? BookmarkStrings.hideBar : nil }
        ActionTargetTitles.setPaletteSettingState("bookmark.toggleBar", in: registry) { services.bookmarks.isBarShown }
        registry.bind("bookmark.manager", run: { _ in services.bookmarkPages.open() })
        registry.bind("bookmark.import", run: { invocation in
            let profile = resolver.profile(invocation)
            guard let path = invocation.callerNamedSource("path") else {
                return BookmarkFiles(services: services).chooseImport(profile: profile)
            }
            BookmarkFiles(services: services).importFile(URL(filePath: (path as NSString).expandingTildeInPath), profile: profile)
        })
        registry.bind("bookmark.importFromBrowser", run: { invocation in
            let profile = resolver.profile(invocation)
            let window = context.activeWindow?.window
            guard let browser = invocation.callerNamedSource("browser") else {
                return BookmarkBrowserImport(services: services).choose(profile: profile, window: window)
            }
            // CLI and agents (bookmarks are not secrets, I5): name the browser, optionally the profile.
            let source = invocation["source"]?.stringValue
            registry.trackOrRefuse(Task { @MainActor in
                let found = await Task.detached { BookmarkBrowserImport.sources(environment: BookmarkBrowserImport.liveEnvironment()) }.value
                let picked = BookmarkBrowserImport.match(found, browser: browser, source: source)
                guard !picked.isEmpty else {
                    return ActionWorkFailure(BookmarkAppStrings.importUnknownSource([browser, source].compactMap { $0 }.joined(separator: " ")))
                }
                let work = BookmarkBrowserImport(services: services)
                let outcome = await work.run(picked, target: profile)
                work.announce(outcome, in: window)
                guard !outcome.failed.isEmpty else { return nil }
                var failure = ActionWorkFailure(BookmarkAppStrings.importFailed(outcome.failed.joined(separator: ", ")))
                failure.shown = true // its toast named the failed sources: a run nobody awaits shows no second notice
                return failure
            })
        })
        registry.bind("bookmark.export", run: { invocation in
            let profile = resolver.profile(invocation)
            guard let path = invocation.callerNamedSource("path") else {
                return BookmarkFiles(services: services).chooseExport(profile: profile)
            }
            BookmarkFiles(services: services).exportFile(URL(filePath: (path as NSString).expandingTildeInPath), profile: profile)
        })
    }

    private static func apply(_ services: AppServices, _ ops: [BookmarkRoutedClient.Op]) async throws {
        do { try await services.bookmarks.apply(ops) } catch {
            throw ActionFailure(message: BookmarkAppStrings.failure(error))
        }
    }

    private static func open(_ invocation: ActionInvocation, _ resolver: BookmarkResolver, _ services: AppServices,
                             _ disposition: BookmarkOpenDisposition) {
        resolver.withNode(invocation) { node, profile in try await open(node, profile, invocation, services, disposition) }
    }

    private static func open(_ node: BookmarkNode, _ profile: String, _ invocation: ActionInvocation, _ services: AppServices,
                             _ disposition: BookmarkOpenDisposition) async throws {
        let opener = BookmarkOpener(services: services)
        guard node.isFolder else {
            // Agents never open Chromium's own pages, also not through a bookmark (AgentURLPolicy).
            if invocation.origin != .user, let url = node.url, AgentURLPolicy.refuses(url) {
                throw ActionFailure(message: MiscHandlerStrings.agentChromiumPage)
            }
            return opener.open(node, profile: profile, disposition: disposition)
        }
        let links = try await opener.links(in: node.id, profile: profile)
        if invocation.origin != .user, links.contains(where: { $0.url.map(AgentURLPolicy.refuses) == true }) {
            throw ActionFailure(message: MiscHandlerStrings.agentChromiumPage)
        }
        opener.open(links, profile: profile)
    }

    /// With a name or URL argument the edit applies at once (CLI); else the
    /// manager page opens on the bookmark.
    private static func edit(_ invocation: ActionInvocation, _ resolver: BookmarkResolver, _ services: AppServices) {
        let title = invocation["title"]?.stringValue
        // A `url` argument resolves with the bookmark: a typed URL, or the refusal.
        resolver.withResolved(invocation, bookmark: true) { resolved, _ in
            guard let node = resolved.bookmark else { throw ActionFailure(message: BookmarkAppStrings.notFound) }
            guard title != nil || resolved.url != nil else { return services.bookmarkPages.open(selecting: node.id) }
            try await apply(services, [.update(id: node.id, title: title, url: resolved.url)])
        }
    }

    /// Every web page tab of the window into a new folder (Bookmark All Tabs), as Chrome
    /// bookmarks a window's tabs: every pane of every screen it shows, in layout order,
    /// session-local pages included. A tab keeps its browser profile, so each profile gets
    /// its own folder; an explicit `profile` takes only that profile's tabs.
    private static func addAllTabs(_ invocation: ActionInvocation, _ context: AppActionContext, _ resolver: BookmarkResolver) throws {
        let services = context.services
        guard let pane = context.paneController(invocation) else { return }
        let only = invocation["profile"] == nil ? nil : resolver.profile(invocation)
        var folders: [(profile: String, pages: [(title: String, url: URL)])] = []
        for (id, model) in pane.workspace?.tabsInLayoutOrder() ?? pane.pane.tabs.map({ (id: $0.id, model: Optional($0)) }) {
            let page = services.cache.existingBrowser(id)?.tab
            guard model.map({ $0.kind == .browser }) ?? (page != nil),
                  let url = page?.state.url ?? model?.url.flatMap(URL.init(string:)), BookmarkService.canBookmark(url) else { continue }
            let profile = services.bookmarks.profile(ofTab: id)
            guard only.map({ $0 == profile }) ?? true else { continue }
            let link = (title: page?.state.title ?? model?.titleText ?? url.absoluteString, url: url)
            if let index = folders.firstIndex(where: { $0.profile == profile }) { folders[index].pages.append(link) } else { folders.append((profile, [link])) }
        }
        guard !folders.isEmpty else { throw ActionFailure(message: BookmarkAppStrings.noTabs) }
        let name = invocation["name"]?.stringValue ?? BookmarkAppStrings.allTabsFolder
        let bookmarks = services.bookmarks
        // One folder per profile, in its default folder (the last one used, while it still is one).
        services.registry.trackOrRefuse(Task {
            do {
                for folder in folders {
                    let parent = try await bookmarks.routed.resolve(profile: folder.profile, folder: .some(nil),
                                                                    fallback: bookmarks.lastFolder[folder.profile]).folder
                    try await apply(services, [.importNodes([BookmarkRoutedClient.Op.folderNode(name, links: folder.pages)],
                                                            profile: folder.profile, parent: parent ?? BookmarkRoot.bar.rawValue)])
                }
                return nil
            } catch let failure as ActionFailure {
                return ActionWorkFailure(failure.message)
            } catch {
                return ActionWorkFailure(BookmarkAppStrings.failure(error))
            }
        })
    }
}
