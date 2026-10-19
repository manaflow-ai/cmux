public import Foundation

/// Whether a Chief's animated picture (a GIF or animated WebP) moves (`home.chiefPictureMotion`,
/// backgrounds plan phase 5): always, only while the pointer is over it, or never. Reduce Motion
/// always shows the still first frame.
public nonisolated enum ChiefPictureMotion: String, CaseIterable, Sendable {
    case always
    case hover
    case never

    /// The motion to draw with now: `never` under Reduce Motion.
    @MainActor public static var effective: ChiefPictureMotion {
        Motion.reduceMotion ? .never : DesignSettings.shared.chiefPictureMotion
    }
}
