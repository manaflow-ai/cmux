import Foundation

/// The hosts a pooled page view serves (one scheme handler for every first-party page): the
/// document it shows now (``PageWebView/servedDescriptor``, with the bound page's dynamic prefixes
/// and source while a shell page is claimed), and every other first-party page that has a document
/// of its own and a root, each under its own CSP. A host that is not first party, or a first-party
/// id with no registered descriptor or no root, is refused.
enum PageServedHosts {
    static func served(host: String, current: PageDescriptor, dynamicSource: (any PageDynamicResourceSource)?,
                       pages: [PageDescriptor] = PageDescriptor.navigablePages,
                       root: (PageDescriptor) -> URL? = PageWebView.servedRoot(for:)) -> PageSchemeHandler.Served? {
        let host = host.lowercased()
        guard PageID.isFirstParty(host) else { return nil }
        if host == current.id.lowercased() {
            return root(current).map { PageSchemeHandler.Served(page: current, root: $0, dynamicSource: dynamicSource) }
        }
        guard let page = pages.first(where: { $0.id.lowercased() == host }), !page.inShell,
              let root = root(page) else { return nil }
        return PageSchemeHandler.Served(page: page, root: root, dynamicSource: nil)
    }
}
