import Foundation

/// The words of web updates (Resources/Localizable.xcstrings).
extension WebUpdatePointer {
    /// The quiet note after this update swaps in: "Updated to 1a2b3c4".
    public var updatedNote: String {
        String(format: String(localized: "updater.web.updated", defaultValue: "Updated to %@", bundle: .module),
               String(commit.prefix(7)))
    }
}
