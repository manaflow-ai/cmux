import Foundation

public enum URLDisplay {
    public static func title(for urlString: String) -> String {
        if urlString == "about:blank" {
            return "New Tab"
        }

        guard let url = URL(string: urlString) else {
            return urlString
        }

        if url.host == "www.google.com", url.path == "/search" {
            return "Search"
        }

        if let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }

        return urlString
    }
}
