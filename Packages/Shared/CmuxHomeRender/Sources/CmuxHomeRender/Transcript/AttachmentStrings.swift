import Foundation

/// User-facing strings of attachment rows (Resources/Localizable.xcstrings).
/// Nonisolated: file chips are laid out on the main actor and drawn off it.
enum AttachmentStrings {
    static var kindPDF: String { String(localized: "attachment.kind.pdf", defaultValue: "PDF Document", bundle: .module) }
    static var kindArchive: String { String(localized: "attachment.kind.archive", defaultValue: "Archive", bundle: .module) }
    static var kindImage: String { String(localized: "attachment.kind.image", defaultValue: "Image", bundle: .module) }
    static var kindVideo: String { String(localized: "attachment.kind.video", defaultValue: "Video", bundle: .module) }
    static var kindAudio: String { String(localized: "attachment.kind.audio", defaultValue: "Audio", bundle: .module) }
    static var kindText: String { String(localized: "attachment.kind.text", defaultValue: "Text Document", bundle: .module) }
    static var kindDocument: String { String(localized: "attachment.kind.document", defaultValue: "Document", bundle: .module) }

    /// VoiceOver label of an image bubble: "Photo, beach.jpg".
    static func photo(_ name: String) -> String {
        String(format: String(localized: "ax.attachment.photo", defaultValue: "Photo, %@", bundle: .module), name)
    }

    /// VoiceOver label of a video bubble: "Video, demo.mov".
    static func video(_ name: String) -> String {
        String(format: String(localized: "ax.attachment.video", defaultValue: "Video, %@", bundle: .module), name)
    }

    /// VoiceOver label of a file chip: "report.pdf, PDF Document, 1.2 MB".
    static func file(name: String, kind: String, size: String) -> String {
        String(format: String(localized: "ax.attachment.file", defaultValue: "%1$@, %2$@, %3$@", bundle: .module), name, kind, size)
    }
}
