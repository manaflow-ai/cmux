import CmuxSessionIndex
import Foundation

// The transcript data value types (`SessionTranscriptRole`, `SessionTranscriptTurn`,
// `SessionTranscriptDisplayRow`) live in CmuxSessionIndex/Transcript, and the role's
// SwiftUI Color/Font presentation now lives in CmuxSessionIndexUI/Transcript
// (`SessionTranscriptRole+Presentation`). Only the localized `label` stays app-side:
// `String(localized:)` must resolve against the app bundle (the package bundle lacks
// the keys). The transcript preview view resolves it via
// `SessionTranscriptPreviewStrings.roleLabel`.
extension SessionTranscriptRole {
    var label: String {
        switch self {
        case .user:
            return String(localized: "sessionIndex.preview.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "sessionIndex.preview.role.assistant", defaultValue: "Agent")
        case .system:
            return String(localized: "sessionIndex.preview.role.system", defaultValue: "System")
        case .tool:
            return String(localized: "sessionIndex.preview.role.tool", defaultValue: "Tool")
        case .event:
            return String(localized: "sessionIndex.preview.role.event", defaultValue: "Event")
        }
    }
}
