import Foundation

nonisolated struct BrowserFaviconRequest: Equatable, Sendable {
    let pageOrigin: String
    let iconURLString: String
    let cachePartition: String

    init?(pageURL: URL, iconURL: URL, cachePartition: String) {
        self.init(pageURL: pageURL, iconURLString: iconURL.absoluteString, cachePartition: cachePartition)
    }

    init?(pageURL: URL, iconURLString: String, cachePartition: String) {
        guard let pageOrigin = Self.pageOrigin(for: pageURL) else { return nil }
        self.init(pageOrigin: pageOrigin, iconURLString: iconURLString, cachePartition: cachePartition)
    }

    init(pageOrigin: String, iconURLString: String, cachePartition: String) {
        self.pageOrigin = pageOrigin
        self.iconURLString = iconURLString
        self.cachePartition = cachePartition.isEmpty ? "default" : cachePartition
    }

    var iconCacheKey: String {
        "\(cachePartition)\nicon:\(iconURLString)"
    }

    var originCacheKey: String {
        "\(cachePartition)\norigin:\(pageOrigin)"
    }

    static func pageOrigin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url?.absoluteString
    }
}
