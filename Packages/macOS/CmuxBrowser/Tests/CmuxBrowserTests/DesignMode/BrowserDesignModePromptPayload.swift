import CmuxBrowser
import Foundation

nonisolated struct BrowserDesignModePromptPayload: Decodable {
    struct Element: Decodable {
        let selection: BrowserDesignModeSelection
        let screenshotPath: String?

        private enum CodingKeys: String, CodingKey {
            case selection
            case screenshotPath = "screenshot_path"
        }
    }

    let pageURL: String
    let snapshot: BrowserDesignModeSnapshot
    let screenshotPath: String?
    let elements: [Element]
    let requestedChange: String

    private enum CodingKeys: String, CodingKey {
        case pageURL = "page_url"
        case snapshot
        case screenshotPath = "screenshot_path"
        case elements
        case requestedChange = "requested_change"
    }
}
