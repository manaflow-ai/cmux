public import Foundation

/// `NSMenuItem.representedObject` payload for a file-external-open menu item:
/// the file to act on plus the chosen ``FileExternalOpenMenuPayloadAction``.
///
/// An `NSObject` so it can ride on `NSMenuItem.representedObject`;
/// ``FileExternalOpenMenuActionTarget`` reads it back when an item is chosen.
public final class FileExternalOpenMenuActionPayload: NSObject {
    /// The file the menu item acts on.
    public let fileURL: URL
    /// What to do with ``fileURL`` when the item is chosen.
    public let action: FileExternalOpenMenuPayloadAction

    /// Creates a payload pairing a file with the action to perform on it.
    public init(fileURL: URL, action: FileExternalOpenMenuPayloadAction) {
        self.fileURL = fileURL
        self.action = action
    }
}
