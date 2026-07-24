import Foundation

/// The complete structured design-mode context written to a handoff JSON file.
struct BrowserDesignModePromptPayload: Encodable {
    let pageURL: String
    let requestedChange: String
    let pageScreenshotPath: String?
    let revision: Int
    let cssDiff: String
    let edits: [BrowserDesignModeEdit]
    let selections: [BrowserDesignModePromptPayloadSelection]
    let prompt: [BrowserDesignModePromptPayloadSegment]

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

    init(context: BrowserDesignModePromptContext) {
        let snapshot = context.snapshot
        pageURL = context.pageURL
        requestedChange = context.requestedChange.trimmingCharacters(in: .whitespacesAndNewlines)
        pageScreenshotPath = context.pageScreenshotPath
        revision = snapshot.revision
        cssDiff = snapshot.cssDiff
        edits = snapshot.edits
        selections = snapshot.selections.enumerated().map { index, selection in
            BrowserDesignModePromptPayloadSelection(
                selection: selection,
                screenshotPath: context.screenshotPaths.indices.contains(index)
                    ? context.screenshotPaths[index]
                    : nil
            )
        }
        prompt = Self.promptSegments(runs: context.prompt, selections: snapshot.selections)
    }

    private static func promptSegments(
        runs: [BrowserDesignModePromptRun],
        selections: [BrowserDesignModeSelection]
    ) -> [BrowserDesignModePromptPayloadSegment] {
        var selectionIndices: [String: Int] = [:]
        for (index, selection) in selections.enumerated()
        where selectionIndices[selection.selector] == nil {
            selectionIndices[selection.selector] = index
        }
        var segments: [BrowserDesignModePromptPayloadSegment] = []
        var resolvedToken = false
        for run in runs {
            switch run {
            case .text(let value):
                if case .text(let previous) = segments.last {
                    segments[segments.count - 1] = .text(previous + value)
                } else if !value.isEmpty {
                    segments.append(.text(value))
                }
            case .token(let identity):
                guard let index = selectionIndices[identity] else {
                    continue
                }
                segments.append(.selection(index))
                resolvedToken = true
            }
        }
        return resolvedToken ? segments : []
    }
}
