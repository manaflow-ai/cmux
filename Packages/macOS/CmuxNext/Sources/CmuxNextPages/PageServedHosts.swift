import Foundation

/// Resolves the bundled page origins a pooled host is allowed to serve.
///
/// The spare never serves file pages or arbitrary origins. Keeping this table to bundled React
/// pages also prevents a pooled WebKit view from acquiring a TCC-sensitive file URL.
enum PageServedHosts {
    static let pooledDescriptors: [PageDescriptor] = [.settings, .history, .cloud]

    static func served(host: String, current: PageDescriptor,
                       dynamicSource: (any PageDynamicResourceSource)?) -> PageSchemeHandler.Served? {
        let lowered = host.lowercased()
        guard let page = pooledDescriptors.first(where: { $0.id.lowercased() == lowered }) else { return nil }
        guard let root = PageWebView.servedRoot(for: page) else { return nil }
        return PageSchemeHandler.Served(page: page, root: root,
                                        dynamicSource: page.id == current.id ? dynamicSource : nil)
    }
}
