import CmuxBrowser
import Foundation

struct BrowserValidatedFileNavigationAllowance {
    private var expectedURLString: String?

    @discardableResult
    func routeRestrictedFileNewTabIntent(
        isFileOnly: Bool,
        isFileURL: Bool,
        shouldOpenInNewTab: Bool,
        route: () -> Void
    ) -> Bool {
        guard isFileOnly, isFileURL, shouldOpenInNewTab else { return false }
        route()
        return true
    }

    func targetsSameDocument(_ candidate: URL, as current: URL) -> Bool {
        guard candidate.browserIsLocalFileURL, current.browserIsLocalFileURL else {
            return false
        }
        return candidate.standardizedFileURL.path == current.standardizedFileURL.path
            && candidate.query == current.query
    }

    mutating func authorize(_ url: URL) -> Bool {
        guard url.browserIsLocalFileURL else {
            expectedURLString = nil
            return false
        }
        expectedURLString = url.absoluteString
        return true
    }

    mutating func consumeIfMatches(
        _ url: URL,
        targetFrameIsMainFrame: Bool?
    ) -> Bool {
        defer { expectedURLString = nil }
        guard targetFrameIsMainFrame == true else { return false }
        return expectedURLString == url.absoluteString
    }

    mutating func clear() {
        expectedURLString = nil
    }
}
