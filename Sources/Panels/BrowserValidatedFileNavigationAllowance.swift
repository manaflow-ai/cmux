import CmuxBrowser
import Foundation

struct BrowserValidatedFileNavigationAllowance {
    private var expectedURLString: String?

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
