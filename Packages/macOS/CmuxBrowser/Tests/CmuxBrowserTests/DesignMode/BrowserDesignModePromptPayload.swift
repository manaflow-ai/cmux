import CmuxBrowser
import Foundation

/// Test-side mirror of the lean prompt payload: one ordered selections array
/// (each entry a flattened selection plus its screenshot path), no duplicated
/// selection objects, empty fields omitted.
nonisolated struct BrowserDesignModePromptPayload: Decodable {
    struct SelectionEntry: Decodable {
        let selection: BrowserDesignModeSelection
        let screenshotPath: String?

        private enum CodingKeys: String, CodingKey {
            case screenshotPath = "screenshot_path"
        }

        init(from decoder: any Decoder) throws {
            selection = try BrowserDesignModeSelection(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            screenshotPath = try container.decodeIfPresent(String.self, forKey: .screenshotPath)
        }
    }

    let pageURL: String
    let requestedChange: String
    let pageScreenshotPath: String?
    let revision: Int
    let cssDiff: String
    let edits: [BrowserDesignModeEdit]
    let selections: [SelectionEntry]

    private enum CodingKeys: String, CodingKey {
        case pageURL = "page_url"
        case requestedChange = "requested_change"
        case pageScreenshotPath = "page_screenshot_path"
        case revision
        case cssDiff = "css_diff"
        case edits
        case selections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageURL = try container.decode(String.self, forKey: .pageURL)
        requestedChange = try container.decode(String.self, forKey: .requestedChange)
        pageScreenshotPath = try container.decodeIfPresent(String.self, forKey: .pageScreenshotPath)
        revision = try container.decode(Int.self, forKey: .revision)
        cssDiff = try container.decodeIfPresent(String.self, forKey: .cssDiff) ?? ""
        edits = try container.decodeIfPresent([BrowserDesignModeEdit].self, forKey: .edits) ?? []
        selections = try container.decode([SelectionEntry].self, forKey: .selections)
    }
}
