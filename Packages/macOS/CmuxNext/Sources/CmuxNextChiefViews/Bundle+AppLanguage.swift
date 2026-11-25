import CmuxNextCompat
import Foundation

extension Bundle {
    /// This module's strings in the app's language (`app.language`, ``AppLanguage``): every
    /// `String(localized:bundle:)` here passes it instead of `.module`, so the text switches live.
    nonisolated static var localizedModule: Bundle { Bundle.module.inAppLanguage }
}
