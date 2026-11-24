import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextTabs
import CmuxNextTerminal
import CoreGraphics

/// Hover-card thumbnails: a live snapshot while the tab has a surface, else
/// the last preview kept in the 32 MB LRU. The New Tab and blank pages
/// picture nothing (a flat page in the theme background), and neither does a
/// flat capture (a page that had not painted, a terminal with only its prompt):
/// the card shows no thumbnail. A page tab's (Markdown, a diff, Settings) comes from ``PageTabPictures``; a chat's from ``AgentPanePictures``.
final class TabPreviewSource: TabPreviewProvider {
    unowned let cache: TabContentCache
    let pages: InternalPageTabStore  // AppServices owns both; the store holds nothing of this
    let chats: AgentPanePictures
    /// Live pictures for the hover cards that show a tab (``makeWatch()``).
    private(set) lazy var watch: PanePictureWatch = makeWatch()

    init(cache: TabContentCache, pages: InternalPageTabStore, images: AgentPaneLaunchImages, chats: @escaping @MainActor (String) -> AgentPaneView?) {
        (self.cache, self.pages) = (cache, pages)
        self.chats = AgentPanePictures(view: chats, images: images, keep: { [previews = cache.previews] in previews.insert($1, for: $0) })
    }

    func previewImage(for tab: TabID, maxPixelSize: CGSize) async -> CGImage? {
        if let page = pages.existingView(tab.rawValue) { return await pages.pictures.picture(of: page, maxPixelSize: maxPixelSize) }
        let image = await chats.picture(tab.rawValue, fit: maxPixelSize) { await cache.previewImage(for: tab.rawValue, maxPixelSize: maxPixelSize) }
        return await Self.shown(image, key: tab.rawValue, cache: cache)
    }

    func watchPreview(for tab: TabID, maxPixelSize: CGSize, onImage: @escaping @MainActor (CGImage) -> Void) -> (@MainActor () -> Void)? {
        watch.watch(tab.rawValue, maxPixelSize: maxPixelSize, onPicture: onImage)
    }

    func invalidatePreviews() { watch.invalidateAll() }

    /// What a tab or screen card or a drag ghost pictures of `key`'s `image`: nothing on the
    /// New Tab page, and nothing for a flat capture, a page's or a terminal's (a shell showing
    /// only its prompt over a see-through background pictured as an empty gray well, Leo
    /// 2026-10-20).
    static func shown(_ image: CGImage?, key: String, cache: TabContentCache) async -> CGImage? {
        if let page = cache.browsers[key]?.tab, BrowserNewTabPage.isNewTabPage(page.state.url) { return nil }
        guard let image else { return nil }
        return await ThumbnailStats.measure(image)?.isBlank == true ? nil : image
    }
}

/// How each kind of tab is pictured live for a hover card that shows it (`PanePictureWatch`): what its content
/// revision is, what tells it changed, and its capture. Each looks its tab up when asked, so a terminal attached
/// again or a chat made later is the one pictured.
extension TabPreviewSource {
    /// The watch the sidebar's and tabs' hover cards share.
    func makeWatch() -> PanePictureWatch {
        PanePictureWatch { [weak self] key in self?.watchSource(key) }
    }

    private func watchSource(_ key: String) -> PanePictureWatch.Source {
        if cache.terminals[key] != nil { return terminalSource(key) }
        if chats.revision(key) != nil { return chatSource(key) }
        if cache.browsers[key] != nil { return browserSource(key) }
        // A page tab (Markdown, a diff, Settings: ``PageTabPictures`` keeps its own), a released chat, an evicted
        // terminal: its last picture, once per watch.
        return PanePictureWatch.Source(gap: PanePictureWatch.pageGap, revision: { nil }, observe: { _ in {} }) { [weak self] size in
            .kept(await self?.previewImage(for: .init(key), maxPixelSize: size))
        }
    }

    /// A terminal: its frame count, told on its first change after each picture; a frame rendered off the main thread.
    private func terminalSource(_ key: String) -> PanePictureWatch.Source {
        PanePictureWatch.Source(gap: PanePictureWatch.terminalGap,
                                revision: { [weak cache] in cache?.terminals[key]?.session.frameChanges.generation },
                                observe: { [weak cache] changed in cache?.terminals[key]?.session.watchPicture(changed) ?? {} }) { [weak self] size in
            guard let self, let session = self.cache.terminals[key]?.session else { return .failed }
            session.rearmPictureWatch()  // the next change after this picture tells the watch again
            let image = await self.cache.previewImage(for: key, maxPixelSize: size)
            guard let shown = await Self.shown(image, key: key, cache: self.cache) else { return .kept(nil) }  // its prompt only
            return .picture(shown)
        }
    }

    /// A chat: its page's push count, told after the page drew a push; its page as a PNG (``AgentPanePictures``).
    private func chatSource(_ key: String) -> PanePictureWatch.Source {
        PanePictureWatch.Source(gap: PanePictureWatch.pageGap,
                                revision: { [weak self] in self?.chats.revision(key) },
                                observe: { [weak self] changed in self?.chats.observe(key, changed) ?? {} }) { [weak self] size in
            guard let self else { return .failed }
            switch await self.chats.livePicture(key, fit: size) {
            case .picture(let image): return .picture(image)
            case .failed, .busy: return .failed  // tried again after a backoff
            case .hidden:  // a hidden Chromium page cannot be pictured: its leave picture
                return .kept(await self.cache.previewImage(for: key, maxPixelSize: size))
            }
        }
    }

    /// A browser page: its picture version (a navigation, a title, a load), observed; pictured while on screen.
    private func browserSource(_ key: String) -> PanePictureWatch.Source {
        PanePictureWatch.Source(gap: PanePictureWatch.pageGap,
                                revision: { [weak cache] in cache?.browsers[key].map { UInt64($0.tab.state.pictureVersion) } },
                                observe: { [weak cache] in cache?.browsers[key]?.tab.watchPictureVersion($0) ?? {} }) { [weak self] size in
            guard let self, let entry = self.cache.browsers[key] else { return .failed }
            let image = await self.cache.previewImage(for: key, maxPixelSize: size)
            let shown = await Self.shown(image, key: key, cache: self.cache)
            // A hidden page returns its last picture: kept, not taken again until it changes or shows.
            guard let shown, self.cache.pagePictureIsCurrent(entry, key: key) else { return .kept(shown) }
            return .picture(shown)
        }
    }
}
