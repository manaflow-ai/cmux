import Foundation

/// Credentials and signed challenges never follow an HTTP redirect.
final class InstallAuthRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    // The async delegate form crashes Swift 6.4 SILGen in this module.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
