import CmuxEgress
public import Foundation

/// The session an icon picker's "from a link" download runs on: https only, redirects too; no
/// cookies or cache; 15 s a request, 30 s in all. The person named the link, so its host (and an
/// https host it redirects to) passes the egress gate (docs/privacy.md, "Egress gate").
public enum IconAssetDownloadSession {
    public static func make(for url: URL) -> URLSession {
        Egress.allowNamed(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return Egress.session(site: "CmuxNextIcons.IconAssetDownloadSession", configuration: configuration,
                              delegate: HTTPSOnlyRedirects(), delegateQueue: nil)
    }
}

/// Follows a redirect only to another https URL. The completion-handler form: Swift 6.3's
/// SILGen crashes on the async form's Objective-C thunk.
private nonisolated final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else { return completionHandler(nil) }
        Egress.allowNamed(request.url)
        completionHandler(request)
    }
}
