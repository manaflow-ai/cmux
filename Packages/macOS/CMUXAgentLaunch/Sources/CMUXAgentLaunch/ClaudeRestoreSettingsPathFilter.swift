import Foundation

/// Removes Claude `--settings <path>` arguments whose file cannot be read when
/// a restore plan is built.
///
/// A captured `--settings` path is kept verbatim at capture time: the file
/// exists then, and a user settings file that merely moved must not be
/// forgotten. Launchers such as subrouter (`sr claude`), however, hand Claude
/// an ephemeral `$TMPDIR/subrouter-claude-settings-<rand>/settings.json` and
/// delete it on exit, and Claude refuses to start on a missing settings file
/// ("Settings file not found"). Plan time is the only point where a replayed
/// path can be checked against the filesystem it will actually run on, so
/// the check lives here rather than in the pure argv sanitizer.
///
/// Inline JSON values, an empty value, a dangling `--settings`, and anything
/// after a `--` boundary are left untouched. The path check mirrors the
/// wrapper's merge loader: trim, then expand only a leading `~`.
struct ClaudeRestoreSettingsPathFilter {
    private static let settingsOption = "--settings"
    private static let settingsAssignmentPrefix = "--settings="

    private let isReadableFile: (String) -> Bool

    /// Creates a filter backed by a readable-file lookup.
    ///
    /// - Parameter isReadableFile: Returns whether a path is a readable regular file.
    init(isReadableFile: @escaping (String) -> Bool) {
        self.isReadableFile = isReadableFile
    }

    /// Returns `arguments` without any `--settings` whose file is not readable.
    ///
    /// - Parameter arguments: A planned argv, including the executable as element zero.
    /// - Returns: The same argv with unreadable settings paths removed.
    func removingUnreadableSettingsPaths(from arguments: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--" {
                result.append(contentsOf: arguments[index...])
                break
            }
            if argument == Self.settingsOption, index + 1 < arguments.endIndex {
                let value = arguments[index + 1]
                if isRestorable(value) {
                    result.append(argument)
                    result.append(value)
                }
                index += 2
                continue
            }
            if argument.hasPrefix(Self.settingsAssignmentPrefix) {
                let value = String(argument.dropFirst(Self.settingsAssignmentPrefix.count))
                if isRestorable(value) {
                    result.append(argument)
                }
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    private func isRestorable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first != "{", first != "[" else {
            return true
        }
        return isReadableFile((trimmed as NSString).expandingTildeInPath)
    }
}
