import Foundation

/// One selected page element and its aligned local screenshot path.
struct BrowserDesignModePromptPayloadSelection: Encodable {
    let selection: BrowserDesignModeSelection
    let screenshotPath: String?

    private enum CodingKeys: String, CodingKey {
        case screenshotPath = "screenshot_path"
    }

    func encode(to encoder: any Encoder) throws {
        try selection.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(screenshotPath, forKey: .screenshotPath)
    }
}
