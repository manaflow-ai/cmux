import CmuxNextDictation
import Foundation

/// The words of Share Screen with Chief (this package's `Localizable` table).
enum ChiefScreenShareStrings {
    static var indicatorTitle: String {
        String(localized: "chiefScreenShare.indicator.title", defaultValue: "Chief can see your screen", bundle: .localizedModule)
    }

    static var headerLabel: String {
        String(localized: "chiefScreenShare.header.label", defaultValue: "Share Screen with Chief", bundle: .localizedModule)
    }

    static var notSharing: String {
        String(localized: "chiefScreenShare.refusal.notSharing", defaultValue: "You are not sharing your screen with Chief.", bundle: .localizedModule)
    }

    static var needsPermission: String {
        String(localized: "chiefScreenShare.refusal.permission",
               defaultValue: "Allow cmux Computer Use in System Settings > Privacy & Security > Screen & System Audio Recording. Sharing starts by itself.",
               bundle: .localizedModule)
    }

    static var helperNotRunning: String {
        String(localized: "chiefScreenShare.refusal.helperNotRunning",
               defaultValue: "Screen sharing with Chief starts when the cmux Computer Use helper runs. Turn on Computer Use in Settings if it is off.",
               bundle: .localizedModule)
    }

    static var failed: String {
        String(localized: "chiefScreenShare.refusal.failed", defaultValue: "Screen sharing with Chief stopped: cmux can no longer read the screen.",
               bundle: .localizedModule)
    }

    static func text(_ error: ChiefScreenShareError) -> String {
        switch error {
        case .notSharing: notSharing
        case .unreadable: failed
        }
    }
}
