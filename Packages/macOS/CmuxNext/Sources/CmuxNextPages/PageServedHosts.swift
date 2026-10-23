import Foundation

/// Resolves the bundled page origins a pooled host is allowed to serve.
///
/// The spare never serves file pages or arbitrary origins. Keeping this table to bundled React
/// pages also prevents a pooled WebKit view from acquiring a TCC-sensitive file URL.
enum PageServedHosts {
    static let pooledDescriptors: [PageDescriptor] = [.settings, .history, .cloud]

    /// The page a pooled host serves at `host`, from the directory `root` gives for it (the
    /// bundled roots by default).
    static func served(host: String, current: PageDescriptor,
                       dynamicSource: (any PageDynamicResourceSource)?,
                       root: (PageDescriptor) -> URL? = { PageWebView.servedRoot(for: $0) }) -> PageSchemeHandler.Served? {
        let lowered = host.lowercased()
        guard let page = pooledDescriptors.first(where: { $0.id.lowercased() == lowered }) else { return nil }
        guard let root = root(page) else { return nil }
        return PageSchemeHandler.Served(page: page, root: root,
                                        dynamicSource: page.id == current.id ? dynamicSource : nil)
    }
}
