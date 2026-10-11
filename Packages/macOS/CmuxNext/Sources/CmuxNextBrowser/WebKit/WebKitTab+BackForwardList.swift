import Foundation
import WebKit

extension WebKitTab: BrowserBackForwardListing {
    public func navigationList() -> BrowserNavigationList? {
        let list = webView.backForwardList
        guard let current = list.currentItem else { return nil }
        let back = list.backList
        let items = back + [current] + list.forwardList
        return BrowserNavigationList(entries: items.map { BrowserNavigationEntry(url: $0.url, title: $0.title) }, current: back.count)
    }

    @discardableResult
    public func goToEntry(offset: Int) -> Bool {
        guard let item = webView.backForwardList.item(at: offset) else { return false }
        webView.go(to: item)
        return true
    }
}
