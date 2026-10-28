/// Which page opened which with a live `window.opener`: the pages an engine made for a page's
/// `window.open` or `target=_blank` with an opener and handed to the host as tabs
/// (``BrowserTabIntent/adoptTab(_:_:)``). Script can reach each from the other: Chrome's browsing
/// instance (content/browser/browsing_instance.h), the group `FreezingPolicy` freezes and discards
/// together (components/performance_manager/freezing/freezing_policy.cc).
///
/// This is not the tab strip's opener model (`BrowserTabOpeners`): a user switch or a typed
/// navigation does not forget a link here, and a link tab without an opener
/// (``BrowserTabIntent/openURL(_:_:)``) is never one. A link ends when either page goes: a closed
/// or discarded page takes its `window.opener` links with it.
package final class BrowserScriptOpeners {
    private var links: [(child: WeakBrowserTab, opener: WeakBrowserTab)] = []

    package init() {}

    /// The engine made `child` for `opener`, which can reach it from script.
    package func record(child: any BrowserTab, opener: any BrowserTab) {
        links.removeAll { $0.child.page == nil || $0.opener.page == nil || $0.child.page === child }
        links.append((WeakBrowserTab(page: child), WeakBrowserTab(page: opener)))
    }

    /// Whether no link has both its pages alive: there is no opener group, and ``openers(key:)`` is empty.
    package var isEmpty: Bool {
        !links.contains { $0.child.page != nil && $0.opener.page != nil }
    }

    /// Each linked child's opener, by the key `key` gives each page (nil: the page is no tab now).
    package func openers(key: (any BrowserTab) -> String?) -> [String: String] {
        links.reduce(into: [:]) { openers, link in
            guard let child = link.child.page.flatMap(key), let opener = link.opener.page.flatMap(key), child != opener else { return }
            openers[child] = opener
        }
    }
}

/// A page reference that does not keep the page alive.
package struct WeakBrowserTab {
    package weak var page: (any BrowserTab)?

    package init(page: any BrowserTab) {
        self.page = page
    }
}
