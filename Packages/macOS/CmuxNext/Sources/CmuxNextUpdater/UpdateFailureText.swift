import CmuxNextDesign
import Foundation

/// Why an update step failed, as a person reads it: a check, download, install, channel switch or
/// rollback. A system error reads in ``PlainErrorText``'s words (no network, a full disk), a Sparkle
/// failure by its stage, any other as one plain line; never Sparkle's or Cocoa's own text
/// ("Error Domain=SUSparkleErrorDomain Code=2001 …"). Every failure site uses this; logs keep the raw
/// error. Retry stays the sheet's one action. Pure.
nonisolated enum UpdateFailureText {
    /// Sparkle's error domain (`SUSparkleErrorDomain`, `SUErrors.h`).
    static let sparkleDomain = "SUSparkleErrorDomain"

    static func plain(_ error: any Error) -> String {
        // Sparkle wraps the network or file error that stopped it (`NSUnderlyingErrorKey`): those words first.
        if let words = PlainErrorText.words(error) { return words }
        let ns = error as NSError
        if ns.domain == sparkleDomain, let stage = sparkleStage(ns.code) { return stage }
        return generic
    }

    /// The line for a Sparkle error code, by the stage it stopped in (`SUErrors.h`): 1000s read the
    /// feed, 2000s download, 3000s check the archive, 4000s install.
    static func sparkleStage(_ code: Int) -> String? {
        switch code {
        case 1000, 1002, 1004:
            UpdaterStrings.text("updater.failure.feed", "cmux couldn't read the update list. Try again later.")
        case 2000, 2001:
            UpdaterStrings.text("updater.failure.download", "The update didn't download. Check your network, then try again.")
        case 3000, 3001, 3002:
            UpdaterStrings.text("updater.failure.verify", "The downloaded update didn't pass its safety check. Try again.")
        case 4000...4012:
            UpdaterStrings.text("updater.failure.install", "The update didn't install. Try again.")
        default:
            nil
        }
    }

    /// The line for an update failure cmux has no words for.
    static var generic: String {
        UpdaterStrings.text("updater.failure.generic", "Something went wrong with the update. Try again.")
    }
}
