import Foundation

/// Formats workspace change totals for compact list and toolbar chips.
public struct WorkspaceChangesChipTextPolicy: Sendable {
    private let locale: Locale

    /// Creates a formatter for the user's current locale.
    public init() {
        locale = .autoupdatingCurrent
    }

    init(locale: Locale) {
        self.locale = locale
    }

    /// Formats line counts normally and uses a file count for binary-only changes.
    /// - Parameters:
    ///   - filesChanged: Number of changed files.
    ///   - additions: Number of added lines.
    ///   - deletions: Number of deleted lines.
    /// - Returns: Styled-text segments for a workspace changes chip.
    public func text(
        filesChanged: Int,
        additions: Int,
        deletions: Int
    ) -> WorkspaceChangesChipText {
        if filesChanged > 0, additions == 0, deletions == 0 {
            return WorkspaceChangesChipText(
                primary: fileCountText(filesChanged),
                secondary: nil
            )
        }

        return WorkspaceChangesChipText(
            primary: String(
                format: String(
                    localized: "changes.summary.additions",
                    defaultValue: "+%lld",
                    bundle: .module,
                    locale: locale
                ),
                locale: locale,
                additions
            ),
            secondary: String(
                format: String(
                    localized: "changes.summary.deletions",
                    defaultValue: "−%lld",
                    bundle: .module,
                    locale: locale
                ),
                locale: locale,
                deletions
            )
        )
    }

    /// Formats a changed-file count with localized singular and plural text.
    /// - Parameter filesChanged: Number of changed files.
    /// - Returns: A localized file-count string.
    public func fileCountText(_ filesChanged: Int) -> String {
        let format: String
        if filesChanged == 1 {
            format = String(
                localized: "changes.chip.file_count.one",
                defaultValue: "%lld file",
                bundle: .module,
                locale: locale
            )
        } else {
            format = String(
                localized: "changes.chip.file_count.other",
                defaultValue: "%lld files",
                bundle: .module,
                locale: locale
            )
        }
        return String(format: format, locale: locale, filesChanged)
    }
}
