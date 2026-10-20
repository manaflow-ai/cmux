public import Foundation

/// Formats design-mode context into files and text that can be handed to a coding agent.
public struct BrowserDesignModePromptFormatter: Sendable {
    /// Creates a prompt formatter.
    public init() {}

    /// Encodes the complete structured context as deterministic, human-readable JSON.
    /// - Parameter context: The captured page, element, edit, and screenshot context.
    /// - Returns: Pretty-printed UTF-8 JSON suitable for saving beside the screenshots.
    public func contextJSON(for context: BrowserDesignModePromptContext) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(BrowserDesignModePromptPayload(context: context))
    }

    /// Formats the short, human-readable part of a design-mode handoff.
    /// - Parameters:
    ///   - context: The captured page, element, edit, and screenshot context.
    ///   - contextJSONPath: The local path containing the complete structured context.
    /// - Returns: Plain text suitable for copying into an agent composer.
    public func format(
        _ context: BrowserDesignModePromptContext,
        contextJSONPath: String
    ) -> String {
        let selections = context.snapshot.selections
        guard !selections.isEmpty,
              !contextJSONPath.isEmpty,
              context.screenshotPaths.count == selections.count,
              context.screenshotPaths.allSatisfy({ path in
                  guard let path else { return false }
                  return !path.isEmpty
              }) else { return "" }
        let screenshotPaths = context.screenshotPaths.compactMap { $0 }

        let requestedChange = context.requestedChange.trimmingCharacters(in: .whitespacesAndNewlines)
        let composedPrompt = composedPrompt(
            segments: browserDesignModePromptSegments(
                runs: context.prompt,
                selections: selections
            ),
            screenshotPaths: screenshotPaths
        )
        var lines = [
            composedPrompt ?? (requestedChange.isEmpty
                ? String(
                    localized: "browser.designMode.handoff.contextOnly",
                    defaultValue: "Design-mode context for the selected page elements."
                )
                : requestedChange),
            "",
            String(
                localized: "browser.designMode.handoff.pageURL",
                defaultValue: "Page: \(context.pageURL)"
            ),
        ]
        if composedPrompt == nil {
            lines.append(contentsOf: screenshotPaths)
        }

        lines.append(String(
            localized: "browser.designMode.handoff.contextJSON",
            defaultValue: "Details: \(contextJSONPath)"
        ))
        return lines.joined(separator: "\n")
    }

    private func composedPrompt(
        segments: [BrowserDesignModePromptPayloadSegment],
        screenshotPaths: [String]
    ) -> String? {
        guard !segments.isEmpty else { return nil }
        var result = ""
        var previousSegmentWasScreenshot = false
        for segment in segments {
            switch segment {
            case .text(let value):
                guard !value.isEmpty else { continue }
                if previousSegmentWasScreenshot, value.first?.isWhitespace == false {
                    result.append(" ")
                }
                result.append(value)
                previousSegmentWasScreenshot = false
            case .selection(let index):
                guard screenshotPaths.indices.contains(index) else { return nil }
                if result.last?.isWhitespace == false {
                    result.append(" ")
                }
                result.append(screenshotPaths[index])
                previousSegmentWasScreenshot = true
            }
        }
        return result.isEmpty ? nil : result
    }
}
