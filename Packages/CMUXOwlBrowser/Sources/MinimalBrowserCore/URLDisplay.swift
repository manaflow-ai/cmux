import Foundation

public enum URLDisplay {
    public static var newTabTitle: String {
        String(localized: "page.empty.title", defaultValue: "New Tab", bundle: .module)
    }

    public static var searchTitle: String {
        String(localized: "page.search.title", defaultValue: "Search", bundle: .module)
    }

    public static func title(for urlString: String) -> String {
        if urlString == "about:blank" {
            return newTabTitle
        }

        guard let url = URL(string: urlString) else {
            return urlString
        }

        if url.host == "www.google.com", url.path == "/search" {
            return searchTitle
        }

        if let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        return urlString
    }
}
