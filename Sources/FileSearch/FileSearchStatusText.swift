import CmuxFileSearch
import Foundation

/// User-facing text for the Find mode's status line.
enum FileSearchStatusText {
    /// "12 results" (one match is one result, as in VS Code).
    static func resultCount(_ count: Int) -> String {
        String(
            format: String(localized: "fileSearch.status.resultCount", defaultValue: "%lld results"),
            Int64(count)
        )
    }

    /// "3 files".
    static func fileCount(_ count: Int) -> String {
        String(
            format: String(localized: "fileSearch.status.fileCount", defaultValue: "%lld files"),
            Int64(count)
        )
    }

    /// "12 results in 3 files".
    static func summary(results: Int, files: Int) -> String {
        String(
            format: String(localized: "fileSearch.status.summary", defaultValue: "%1$@ in %2$@"),
            resultCount(results),
            fileCount(files)
        )
    }

    /// The status line for the current search state. `nil` hides it.
    static func text(
        phase: FileSearchPhase,
        matchCount: Int,
        fileCount: Int,
        scope: FileSearchScope,
        hasQuery: Bool
    ) -> String? {
        switch phase {
        case .idle:
            if case .unsupported = scope, hasQuery { return unsupported }
            return hasQuery && matchCount > 0 ? summary(results: matchCount, files: fileCount) : nil
        case .searching:
            if matchCount == 0 {
                return String(localized: "fileSearch.status.searching", defaultValue: "Searching…")
            }
            return String(
                format: String(localized: "fileSearch.status.searchingWithResults", defaultValue: "%@, searching…"),
                summary(results: matchCount, files: fileCount)
            )
        case .finished(.completed):
            if matchCount == 0 {
                return String(localized: "fileSearch.status.noResults", defaultValue: "No results found")
            }
            return summary(results: matchCount, files: fileCount)
        case .finished(.limited(let limit)):
            return String(
                format: String(
                    localized: "fileSearch.status.limited",
                    defaultValue: "%@. Search limited to the first %@ results; refine the search to see more."
                ),
                summary(results: matchCount, files: fileCount),
                limit.formatted()
            )
        case .finished(.failed(let failure)):
            return message(for: failure, scope: scope)
        }
    }

    static var unsupported: String {
        String(localized: "fileSearch.status.unsupported", defaultValue: "Search is not available for this folder")
    }

    static func message(for failure: FileSearchFailure, scope: FileSearchScope) -> String {
        switch failure {
        case .ripgrepNotFound:
            switch scope {
            case .remoteSSH(let provider):
                return String(
                    format: String(
                        localized: "fileSearch.error.rgMissingSSH",
                        defaultValue: "ripgrep (rg) is not installed on %@. Install it there to search this folder."
                    ),
                    provider.displayTarget
                )
            case .remoteCloud:
                return String(
                    localized: "fileSearch.error.rgMissingCloud",
                    defaultValue: "ripgrep (rg) is not installed on this Cloud VM. Install it there to search this folder."
                )
            case .local, .unsupported:
                return String(
                    localized: "fileExplorer.search.rgNotInstalled",
                    defaultValue: "ripgrep (rg) is not installed or is not on PATH."
                )
            }
        case .invalidRegex(let detail):
            return regexError(detail: detail)
        case .unavailable(let message):
            return message
        case .processFailed(let status, let message):
            if !message.isEmpty {
                return String(
                    format: String(localized: "fileExplorer.search.failed", defaultValue: "Search failed: %@"),
                    lastLine(of: message)
                )
            }
            return String(
                format: String(localized: "fileExplorer.search.rgExited", defaultValue: "rg exited with status %d"),
                Int(status)
            )
        }
    }

    /// Inline error under the query field. ripgrep's diagnostic spans several
    /// lines ending in the reason; the reason is what the user needs.
    static func regexError(detail: String?) -> String {
        let base = String(localized: "fileSearch.error.invalidRegex", defaultValue: "Invalid regular expression")
        guard let detail, !detail.isEmpty else { return base }
        return "\(base): \(lastLine(of: detail))"
    }

    private static func lastLine(of text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reason = lines.last { $0.lowercased().hasPrefix("error") } ?? lines.last ?? text
        return reason
    }
}
