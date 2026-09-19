import Foundation

#if DEBUG
/// The four native sidebar treatments available in the launch-design preview.
enum CloudAnnouncementPreviewStyle: String, CaseIterable, Identifiable {
    case notificationRow = "row"
    case footerNote = "note"
    case updatePill = "pill"
    case nativeHint = "hint"

    static let selectionKey = "debug.cloudAnnouncement.style"
    static let visibilityKey = "debug.cloudAnnouncement.visible"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notificationRow:
            String(localized: "debug.cloudAnnouncement.row", defaultValue: "A · Notification row")
        case .footerNote:
            String(localized: "debug.cloudAnnouncement.note", defaultValue: "B · Footer note")
        case .updatePill:
            String(localized: "debug.cloudAnnouncement.pill", defaultValue: "C · Update pill")
        case .nativeHint:
            String(localized: "debug.cloudAnnouncement.hint", defaultValue: "D · Native hint")
        }
    }

    var detail: String {
        switch self {
        case .notificationRow:
            String(localized: "debug.cloudAnnouncement.row.detail", defaultValue: "A thin unread line on the sidebar surface.")
        case .footerNote:
            String(localized: "debug.cloudAnnouncement.note.detail", defaultValue: "A quiet footnote above the help controls.")
        case .updatePill:
            String(localized: "debug.cloudAnnouncement.pill.detail", defaultValue: "A small update pill immediately beside help.")
        case .nativeHint:
            String(localized: "debug.cloudAnnouncement.hint.detail", defaultValue: "A compact material hint pointing to help.")
        }
    }
}
#endif
