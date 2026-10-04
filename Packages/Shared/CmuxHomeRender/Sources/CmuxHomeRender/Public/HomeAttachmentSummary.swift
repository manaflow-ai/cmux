public import CmuxHomeCore
import Foundation

/// The localized inbox preview of an attachment-only message
/// (`InboxRow.previewAttachments`): "Photo", "2 photos", "Video",
/// "Voice message", "File". The owner sends no text for these.
public enum HomeAttachmentSummary {
    public static func label(_ preview: AttachmentPreview) -> String {
        let n = max(1, preview.count)
        switch (preview.kind, n) {
        case (.photo, 1): return String(localized: "preview.photo", defaultValue: "Photo", bundle: .module)
        case (.photo, _): return String(localized: "preview.photos", defaultValue: "\(n) photos", bundle: .module)
        case (.video, 1): return String(localized: "preview.video", defaultValue: "Video", bundle: .module)
        case (.video, _): return String(localized: "preview.videos", defaultValue: "\(n) videos", bundle: .module)
        case (.audio, 1): return String(localized: "preview.audio", defaultValue: "Voice message", bundle: .module)
        case (.audio, _): return String(localized: "preview.audios", defaultValue: "\(n) voice messages", bundle: .module)
        case (.file, 1): return String(localized: "preview.file", defaultValue: "File", bundle: .module)
        case (.file, _): return String(localized: "preview.files", defaultValue: "\(n) files", bundle: .module)
        }
    }
}
