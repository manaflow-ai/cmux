import Foundation

/// The words of web updates (Resources/Localizable.xcstrings).
nonisolated public enum WebUpdateStrings {
    /// The quiet note after an update swaps in: "Updated to 1a2b3c4".
    public static func updated(toCommit commit: String) -> String {
        String(format: String(localized: "updater.web.updated", defaultValue: "Updated to %@", bundle: .module),
               String(commit.prefix(7)))
    }
}
