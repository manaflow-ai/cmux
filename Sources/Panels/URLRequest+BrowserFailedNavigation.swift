import Foundation

extension URLRequest {
    func browserMatchesFailedNavigationURLString(_ failedURL: String) -> Bool {
        guard let requestURL = url else { return false }
        guard !failedURL.isEmpty else { return false }
        guard let failed = URL(string: failedURL) else { return false }
        if requestURL.absoluteString == failed.absoluteString {
            return true
        }

        var requestComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        var failedComponents = URLComponents(url: failed, resolvingAgainstBaseURL: false)
        requestComponents?.fragment = nil
        failedComponents?.fragment = nil
        return requestComponents?.url?.absoluteString == failedComponents?.url?.absoluteString
    }
}
