import Foundation

/// Localized update strings (Resources/Localizable.xcstrings, en + ja).
/// Versions, build numbers and URLs are format arguments.
nonisolated enum UpdaterStrings {
    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }

    static func format(_ key: StaticString, _ value: String.LocalizationValue, _ arguments: any CVarArg...) -> String {
        String(format: text(key, value), arguments: arguments)
    }

    // Titles
    static var checking: String { text("updater.title.checking", "Checking for Updates…") }
    static var upToDate: String { text("updater.title.upToDate", "cmux Is Up to Date") }
    static func available(_ version: String) -> String { format("updater.title.available", "cmux %@ Is Available", version) }
    static var availableNoVersion: String { text("updater.title.availableNoVersion", "An Update Is Available") }
    static func needsNewerMacOS(_ version: String) -> String { format("updater.title.needsNewerMacOS", "Update Needs macOS %@", version) }
    static var checkFailed: String { text("updater.title.checkFailed", "Couldn't Check for Updates") }
    static var updateFailed: String { text("updater.title.updateFailed", "Update Failed") }
    static var downloadManually: String { text("updater.button.downloadManually", "Download Manually") }
    static func preflightFolder(_ folder: String) -> String {
        format("updater.preflight.folder", "cmux can't replace itself in %@. Move cmux to Applications, or download the update manually.", folder)
    }
    static var preflightMissing: String {
        text("updater.preflight.missing", "The downloaded update is no longer there. Check for updates again, or download the update manually.")
    }
    static var preflightSpace: String {
        text("updater.preflight.space", "There isn't enough free disk space to install the update. Free some space, or download the update manually.")
    }
    static var managed: String { text("updater.title.managed", "Updates Are Managed") }
    static func managedChannel(_ channel: String) -> String {
        format("updater.managed.channel", "Your organization keeps this Mac on the %@ channel.", channel)
    }
    static func updateRequired(_ version: String) -> String {
        format("updater.required", "Your organization requires cmux %@ or newer.", version)
    }
    static var startingDownload: String { text("updater.title.startingDownload", "Starting Download…") }
    static var downloading: String { text("updater.title.downloading", "Downloading Update") }
    static var preparing: String { text("updater.title.preparing", "Preparing Update") }
    static var installing: String { text("updater.title.installing", "Installing…") }
    static var readyToInstall: String { text("updater.title.readyToInstall", "Update Ready") }
    static var updateAvailableButton: String { text("updater.button.updateAvailable", "Update Available: Click to Download and Install") }
    static func updateAvailableNamed(_ version: String) -> String {
        format("updater.button.updateAvailableNamed", "Update Available (%@): Click to Download and Install", version)
    }

    // Rollback
    static var rollbackNothingKept: String { text("updater.rollback.nothingKept", "No previous version is kept on this Mac.") }
    static func rollbackPredates(_ version: String) -> String {
        format("updater.rollback.predates", "cmux %@ is from before rollback support, so cmux cannot check that it reads your data.", version)
    }
    static func rollbackStoreTooNew(_ version: String, _ store: String, _ stored: Int, _ readable: Int) -> String {
        format("updater.rollback.storeTooNew", "cmux %1$@ cannot read your %2$@ data: it is in format %3$ld and that version reads up to %4$ld. Rolling back would lose it.",
               version, store, stored, readable)
    }
    static func rollbackUnknownStore(_ version: String, _ store: String) -> String {
        format("updater.rollback.unknownStore", "cmux %1$@ does not know your %2$@ data. Rolling back would hide it.", version, store)
    }
    static func rollbackSignature(_ version: String) -> String {
        format("updater.rollback.signature", "The kept cmux %@ is not signed by the cmux team, so it will not run.", version)
    }

    static var rollbackStoresUnknown: String {
        text("updater.rollback.storesUnknown", "The running cmux-tui cannot report its data formats, so cmux cannot check a rollback.")
    }
    // The question every rollback entrypoint asks (UpdateDropBack.confirmation)
    static var rollbackConfirmTitle: String { text("updater.rollback.confirm.title", "Roll Back to the Previous Version?") }
    static var rollbackConfirmBody: String {
        text("updater.rollback.confirm.body", "cmux quits and reopens the build this Mac kept. Your terminals and agents keep running.")
    }

    // Test feed
    static var testFeedRefused: String {
        text("updater.testFeed.refused", "A test update feed needs a DEV or NIGHTLY build and an https address (http only on this Mac).")
    }
    static var testFeedTitle: String { text("updater.testFeed.title", "Test Update Feed") }
    static var testFeedUseReal: String { text("updater.testFeed.useReal", "Use Real Feed") }


    /// The footer pill's tooltip and VoiceOver label (SIDEBAR-FOOTER-MINIMAL):
    /// the relaunch keeps terminals and agents (browser pages reload).
    static var restartKeepsSessions: String {
        text("updater.pill.restartKeepsSessions", "Restart to update. Your terminals and agents keep running.")
    }

    static var restartToUpdate: String { text("updater.card.restartToUpdate", "Restart to Update") }
    static var automaticUpdates: String { text("updater.card.automaticUpdates", "Automatic Updates") }
    static var seeAllChanges: String { text("updater.card.seeAllChanges", "See all changes") }
    static func downloadedHeadline(_ version: String) -> String {
        format("updater.card.downloaded", "Update %@ downloaded. Click to restart and install.", version)
    }
    static var downloadedHeadlineNoVersion: String {
        text("updater.card.downloadedNoVersion", "Update downloaded. Click to restart and install.")
    }
    static var keepsRunning: String { text("updater.card.keepsRunning", "Your terminals and agents keep running.") }
    static var whatsChanged: String { text("updater.card.whatsChanged", "What's changed") }
    static func moreChanges(_ count: Int) -> String {
        count == 1 ? text("updater.card.oneMoreChange", "1 more change") : format("updater.card.moreChanges", "%ld more changes", count)
    }

    // The tips card (BOTTOM-LEFT-CARDS K1)
    static var tipEyebrow: String { text("updater.tip.eyebrow", "Did you know?") }
    static var tipDismiss: String { text("updater.tip.dismiss", "Hide This Tip") }

    // Details
    static func currentVersion(_ version: String, _ build: String) -> String {
        format("updater.detail.currentVersion", "You have cmux %@ (%@).", version, build)
    }
    static func onChannel(_ version: String, _ build: String, _ channel: String) -> String {
        format("updater.detail.onChannel", "cmux %@ (%@) is the newest %@ build.", version, build, channel)
    }
    static func devProbeFound(_ version: String) -> String {
        format("updater.detail.devProbeFound", "The feed offers %@. This development build never installs updates; the check only read the feed.", version)
    }
    static func requiresMacOS(_ version: String, _ required: String, _ system: String) -> String {
        format("updater.detail.requiresMacOS", "cmux %@ requires macOS %@ or later. This Mac runs macOS %@, so it stays on the current version.", version, required, system)
    }
    static var readyDetail: String { text("updater.detail.ready", "Relaunch to finish. Terminals keep running.") }
    // The update notice card (Lawrence 2026-10-09)
    static func youHave(_ version: String) -> String { format("updater.notice.youHave", "You have %@.", version) }
    static func upToDateDetail(_ version: String) -> String {
        format("updater.notice.upToDateDetail", "Version %@, checked just now", version)
    }
    // The loading card through a download and install (Lawrence 2026-10-20).
    static func downloadedOf(_ received: String, _ expected: String, _ percent: String) -> String {
        format("updater.notice.downloadedOf", "%1$@ of %2$@ · %3$@", received, expected, percent)
    }
    static var preparingDetail: String { text("updater.notice.preparingDetail", "Verifying and unpacking the update.") }
    static var installingUpdate: String { text("updater.notice.installingTitle", "Installing Update") }
    static var relaunchingDetail: String {
        text("updater.notice.relaunchingDetail", "cmux relaunches in a moment. Your terminals and agents keep running.")
    }
    static func checkingNewVersion(seconds: Int) -> String {
        format("updater.notice.checkingNewVersion",
               "The installer checks the new version (%lld s). cmux relaunches when it is done. Your terminals and agents keep running.",
               seconds)
    }
    static var installStalled: String { text("updater.notice.stalledTitle", "Update Did Not Relaunch") }
    static func installStalledDetail(minutes: Int) -> String {
        format("updater.notice.stalledDetail", "cmux waited %lld min for the installer. Your windows are back. Details shows the update log.", minutes)
    }
    static var checkFailedDetail: String { text("updater.notice.checkFailedDetail", "Check your connection and try again.") }
    static var noticeDismiss: String { text("updater.notice.dismiss", "Dismiss") }
    // Short notice titles; the version goes in the detail line.
    static var noticeAvailable: String { text("updater.notice.available", "Update Available") }
    // The pulled-build banner (PulledBuildWatch)
    static var pulledTitle: String { text("updater.pulled.title", "This Nightly Was Pulled") }
    static var pulledWait: String { text("updater.pulled.wait", "Wait for the Fix") }
    static var pulledRollBack: String { text("updater.pulled.rollBack", "Roll Back") }
    static func pulledKept(_ version: String) -> String {
        format("updater.pulled.kept", "Roll back to %@, the build this Mac kept, or keep this one until the fixed build installs by itself.", version)
    }
    static var pulledNothingKept: String {
        text("updater.pulled.nothingKept", "The fixed build installs by itself as soon as it is published.")
    }
    static var noticeCheckFailed: String { text("updater.notice.checkFailed", "Update Check Failed") }
    static func foundVersion(_ version: String) -> String { format("updater.notice.foundVersion", "Version %@", version) }
    // The update changelog (cx-lntk)
    static func versionDate(_ version: String, _ date: String) -> String {
        format("updater.changelog.versionDate", "%1$@ · %2$@", version, date)
    }
    static var changelogNew: String { text("updater.changelog.new", "New") }
    static var changelogFixed: String { text("updater.changelog.fixed", "Fixed") }
    static var changelogChanged: String { text("updater.changelog.changed", "Changed") }
    static func needsMacOSDetail(_ version: String, _ required: String) -> String {
        format("updater.notice.needsMacOS", "Needs macOS %1$@ for %2$@", required, version)
    }

    // Buttons
    static var install: String { text("updater.button.install", "Install and Relaunch") }
    static var later: String { text("updater.button.later", "Later") }
    static var cancel: String { text("updater.button.cancel", "Cancel") }
    static var retry: String { text("updater.button.retry", "Try Again") }
    static var done: String { text("updater.button.done", "Done") }
    static var relaunch: String { text("updater.button.relaunch", "Relaunch") }
    static var releaseNotes: String { text("updater.button.releaseNotes", "Release Notes") }
    static var update: String { text("updater.button.update", "Update") }
    static var details: String { text("updater.button.details", "Details") }

    // Channels
    static func channel(_ track: UpdateTrack) -> String {
        switch track {
        case .stable: text("updater.channel.stable", "stable")
        case .nightly: text("updater.channel.nightly", "nightly")
        case .rc: text("updater.channel.rc", "release candidate")
        case .development: text("updater.channel.development", "development")
        }
    }

    // Unavailable reasons
    static var disabledDevelopment: String { text("updater.disabled.development", "Development builds do not install updates.") }
    static var disabledMissingKey: String { text("updater.disabled.missingKey", "This build has no update signing key, so it cannot verify updates.") }
    static var disabledManaged: String { text("updater.disabled.managed", "Your organization manages cmux updates on this Mac.") }
    static var disabledUnknown: String { text("updater.disabled.unknown", "The updater is not available in this build.") }
    static func cannotSwitch(to target: String, from track: String) -> String {
        format("updater.disabled.cannotSwitch", "A %@ build cannot switch to %@.", track, target)
    }
}
