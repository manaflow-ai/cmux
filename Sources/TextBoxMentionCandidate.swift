import CmuxFoundation
import Foundation

struct TextBoxMentionCandidate: Sendable {
    let title: String
    let subtitle: String
    let targetPath: String
    let systemImageName: String
    let searchKey: String
    let priority: Int

    func suggestion(trigger: Character) -> TextBoxMentionSuggestion {
        let displayTitle: String
        if (trigger == "/" || trigger == "$"), (title.hasPrefix("/") || title.hasPrefix("$")) {
            displayTitle = "\(trigger)\(title.dropFirst())"
        } else {
            displayTitle = title
        }

        let insertionText: String
        if trigger == "$" {
            // The $ trigger intentionally inserts the bare skill reference
            // (e.g. "$skill-name") as a plain-text shorthand. The / and @
            // triggers insert a markdown link instead.
            insertionText = displayTitle
        } else {
            insertionText = TextBoxMentionMarkdown.link(label: displayTitle, path: targetPath)
        }

        return TextBoxMentionSuggestion(
            id: "\(trigger):\(targetPath)",
            title: displayTitle,
            subtitle: subtitle,
            insertionText: insertionText,
            systemImageName: systemImageName
        )
    }
}

extension TextBoxMentionCandidate {
    static func directoryCandidate(relativePath: String, directoryURL: URL) -> TextBoxMentionCandidate {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let displayTitle = "@\(normalizedPath)/"
        let directoryName = directoryURL.lastPathComponent
        return TextBoxMentionCandidate(
            title: displayTitle,
            subtitle: directoryURL.path.homeAbbreviatedPath,
            targetPath: directoryURL.path,
            systemImageName: "folder",
            searchKey: "\(normalizedPath) \(directoryName) folder directory".lowercased(),
            priority: directoryPriority(relativePath: normalizedPath)
        )
    }

    static func fileCandidate(
        relativePath: String,
        fileURL: URL,
        fileName: String
    ) -> TextBoxMentionCandidate {
        TextBoxMentionCandidate(
            title: "@\(relativePath)",
            subtitle: fileURL.path.homeAbbreviatedPath,
            targetPath: fileURL.path,
            systemImageName: "doc",
            searchKey: "\(relativePath) \(fileName)".lowercased(),
            priority: filePriority(relativePath: relativePath)
        )
    }

    private static func directoryPriority(relativePath: String) -> Int {
        let depth = max(relativePath.split(separator: "/").count, 1)
        return min((depth * 2) - 2, 40)
    }

    private static func filePriority(relativePath: String) -> Int {
        let depth = max(relativePath.split(separator: "/").count, 1)
        return min((depth * 2) - 1, 41)
    }

    static func sortedFileSystemCandidates(
        _ candidates: [TextBoxMentionCandidate]
    ) -> [TextBoxMentionCandidate] {
        candidates.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}
