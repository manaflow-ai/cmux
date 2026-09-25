import CmuxBrowser
import Foundation

/// Test-side mirror of the context JSON: one ordered selections array with
/// each selection flattened beside its screenshot path.
struct BrowserDesignModePromptPayload: Decodable {
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

    /// A decoded prompt segment: exactly one of text or selection index.
    struct PromptSegment: Decodable, Equatable {
        let text: String?
        let selection: Int?
    }

    let pageURL: String
    let requestedChange: String
    let pageScreenshotPath: String?
    let revision: Int
    let cssDiff: String
    let edits: [BrowserDesignModeEdit]
    let selections: [SelectionEntry]
    let prompt: [PromptSegment]

    private enum CodingKeys: String, CodingKey {
        case pageURL = "page_url"
        case requestedChange = "requested_change"
        case pageScreenshotPath = "page_screenshot_path"
        case revision
        case cssDiff = "css_diff"
        case edits
        case selections
        case prompt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageURL = try container.decode(String.self, forKey: .pageURL)
        requestedChange = try container.decode(String.self, forKey: .requestedChange)
        pageScreenshotPath = try container.decodeIfPresent(String.self, forKey: .pageScreenshotPath)
        revision = try container.decode(Int.self, forKey: .revision)
        cssDiff = try container.decode(String.self, forKey: .cssDiff)
        edits = try container.decode([BrowserDesignModeEdit].self, forKey: .edits)
        selections = try container.decode([SelectionEntry].self, forKey: .selections)
        prompt = try container.decode([PromptSegment].self, forKey: .prompt)
    }
}
