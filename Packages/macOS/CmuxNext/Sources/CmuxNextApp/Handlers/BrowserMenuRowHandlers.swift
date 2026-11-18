import CmuxNextActions
import CmuxNextBrowser

/// Palette rows of two hand-built browser menus, which run these actions themselves so the menu and
/// the palette run one handler:
/// - `browser.goToHistoryEntry` (`entry`: the offset from the current page): a row of the Back and
///   Forward buttons' entry menus (`BrowserChromeView.goToBackForwardEntry`, through
///   `BrowserTabIntent.goToHistoryEntry`); the palette lists the focused tab's entries
///   (`browserBackForwardEntries`).
/// - `browser.download.*` (`download`: the download's id): the rows of a download's menu in the
///   Downloads popup (``BrowserDownloadsMenu``); the palette lists the downloads, newest first (`browserDownloads`).
enum BrowserMenuRowHandlers {
    static let downloadActions: [ActionID] = [
        "browser.download.open", "browser.download.reveal", "browser.download.togglePause",
        "browser.download.retry", "browser.download.cancel", "browser.download.copyLink",
    ]

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindDownloads(into: registry, list: { context.services.cache.pageRequests.downloads })
        bindBackForward(into: registry, page: { BrowserHitHandlers.page($0, context) })
    }

    /// The downloads rows over `list` (the App's one downloads list). The palette offers them while it lists a download.
    static func bindDownloads(into registry: ActionRegistry, list: @escaping @MainActor () -> BrowserDownloadList) {
        for id in downloadActions {
            registry.bindEffect(id, isEnabled: { !list().items.isEmpty }, effect: { invocation in
                let downloads = list()
                let wanted = invocation["download"]?.stringValue
                guard let download = downloads.items.first(where: { $0.id.uuidString == wanted }),
                      BrowserDownloadsMenu.perform(id, on: download, list: downloads) else {
                    return .refused(BrowserHitStrings.downloadUnavailable)
                }
                return .done
            })
        }
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserDownloads else { return other?(source) ?? [] }
            return list().items.reversed().map { ActionEnumCase(value: $0.id.uuidString, title: $0.filename, subtitle: BrowserDownloadsMenu.status($0)) }
        }
    }

    /// Go Back or Forward to… on `page(invocation)` (the invocation's tab, else the focused one).
    static func bindBackForward(into registry: ActionRegistry, page: @escaping @MainActor (ActionInvocation) -> (any BrowserTab)?) {
        let listing = { @MainActor (invocation: ActionInvocation) -> (any BrowserBackForwardListing)? in
            page(invocation) as? any BrowserBackForwardListing
        }
        registry.bindEffect("browser.goToHistoryEntry", effect: { invocation in
            guard let tab = listing(invocation), let list = tab.navigationList() else { return .refused(MiscHandlerStrings.noBrowser) }
            guard let offset = invocation["entry"]?.stringValue.flatMap({ Int($0) }), offset != 0,
                  list.entries.indices.contains(list.current + offset) else {
                return .refused(BrowserHitStrings.historyNoEntry)
            }
            tab.goToEntry(offset: offset)
            return .done
        })
        // Left out where the tab has no earlier or later page (the menus show only then).
        ActionTargetVisibility.gate("browser.goToHistoryEntry", in: registry) { invocation in
            guard let list = listing(invocation)?.navigationList() else { return MiscHandlerStrings.noBrowser }
            return list.back.isEmpty && list.forward.isEmpty ? BrowserHitStrings.historyNoEntry : nil
        }
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { source in
            guard source == ActionSuggestions.browserBackForwardEntries else { return other?(source) ?? [] }
            guard let list = listing(ActionInvocation())?.navigationList() else { return [] }
            return (list.back + list.forward).map { row in
                ActionEnumCase(value: String(row.offset), title: row.entry.menuTitle, subtitle: row.entry.url?.absoluteString)
            }
        }
    }
}
