import CmuxNextCompat
import Foundation

extension Bundle {
    /// This module's strings in the app's language (`app.language`, ``AppLanguage``): every
    /// `String(localized:bundle:)` here passes it instead of `.module`, so the text switches live.
    nonisolated static var localizedModule: Bundle { moduleResources.inAppLanguage }

    /// This module's resource bundle, looked up once. Not SwiftPM's `Bundle.module`: Xcode 27 makes
    /// that main-actor isolated in a main-actor-by-default target, so the nonisolated read above
    /// would not compile there (``Foundation/Bundle/cmuxNextModuleResources(anchor:)``).
    private nonisolated static let moduleResources = cmuxNextModuleResources(anchor: LocalizedModuleAnchor.self)
}

/// A class compiled into this module, which names the module's resource bundle.
private nonisolated final class LocalizedModuleAnchor {}
