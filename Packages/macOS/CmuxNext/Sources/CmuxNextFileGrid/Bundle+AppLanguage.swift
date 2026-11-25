import CmuxNextCompat
import Foundation

extension Bundle {
    /// This module's strings in the app's language (`app.language`, ``AppLanguage``): every
    /// `String(localized:bundle:)` here passes it instead of `.module`, so the text switches live.
    /// Main-actor (this target's default), not `nonisolated`: SwiftPM's `Bundle.module` takes the
    /// target's default isolation on some toolchains, and every reader here is the grid view.
    static var localizedModule: Bundle { Bundle.module.inAppLanguage }
}
