import Foundation

/// An artifact file action rendered by a viewer action bar or host toolbar.
public enum ChatArtifactAction: Hashable, Sendable {
    /// Opens the system share interface for the artifact.
    case share
    /// Exports a copy of the artifact through the Files document picker.
    case save
    /// Copies loaded image data to the system pasteboard.
    case copyImage
    /// Copies the artifact's rendered text contents.
    case copyContents
    /// Copies the artifact's remote path.
    case copyPath

    /// The localized accessibility label for this action.
    public var localizedTitle: String {
        switch self {
        case .share:
            String(localized: "chat.artifact.share", defaultValue: "Share", bundle: .module)
        case .save:
            String(localized: "chat.artifact.save_to_files", defaultValue: "Save to Files", bundle: .module)
        case .copyImage:
            String(localized: "chat.artifact.copy_image", defaultValue: "Copy image", bundle: .module)
        case .copyContents:
            String(localized: "chat.artifact.copy_contents", defaultValue: "Copy contents", bundle: .module)
        case .copyPath:
            String(localized: "chat.artifact.copy_path", defaultValue: "Copy path", bundle: .module)
        }
    }

    /// The SF Symbol name used by artifact action controls.
    public var systemImage: String {
        switch self {
        case .share:
            "square.and.arrow.up"
        case .save:
            "folder.badge.plus"
        case .copyImage:
            "doc.on.doc"
        case .copyContents:
            "doc.on.doc"
        case .copyPath:
            "link"
        }
    }
}
