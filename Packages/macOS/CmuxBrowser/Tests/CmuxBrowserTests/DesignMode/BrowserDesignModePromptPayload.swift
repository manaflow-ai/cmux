import CmuxBrowser
import Foundation

nonisolated struct BrowserDesignModePromptPayload: Decodable {
    let pageURL: String
    let snapshot: BrowserDesignModeSnapshot
    let screenshotPath: String?

    private enum CodingKeys: String, CodingKey {
        case pageURL = "page_url"
        case snapshot
        case screenshotPath = "screenshot_path"
    }
}
