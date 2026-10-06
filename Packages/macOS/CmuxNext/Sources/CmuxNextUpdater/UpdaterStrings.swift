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

    // Test feed
    static var testFeedRefused: String {
        text("updater.testFeed.refused", "A test update feed needs a DEV or NIGHTLY build and an https address (http only on this Mac).")
    }
    static var testFeedTitle: String { text("updater.testFeed.title", "Test Update Feed") }
    static var testFeedUseReal: String { text("updater.testFeed.useReal", "Use Real Feed") }

    static func whatsNewTitle(_ version: String) -> String { format("updater.card.whatsNew", "What's New in cmux %@", version) }

    // R114 card; restartToUpdate is the Settings row control's label.
    static var restartToUpdate: String { text("updater.card.restartToUpdate", "Restart to Update") }
    static var cardWaitingTitle: String { text("updater.card.waitingTitle", "Update Waits for Agents") }
    static func cardWaitingDetail(_ count: Int) -> String {
        format("updater.card.waitingDetail", "Installs when the running agents finish (%ld)", count)
    }
    static var installNow: String { text("updater.button.installNow", "Install Now") }
    /// The footer pill's tooltip and VoiceOver label (SIDEBAR-FOOTER-MINIMAL):
    /// the relaunch keeps terminals and agents (browser pages reload).
    static var restartKeepsSessions: String {
        text("updater.pill.restartKeepsSessions", "Restart to update. Your terminals and agents keep running.")
    }

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

    // Buttons
    static var install: String { text("updater.button.install", "Install and Relaunch") }
    static var later: String { text("updater.button.later", "Later") }
    static var cancel: String { text("updater.button.cancel", "Cancel") }
    static var retry: String { text("updater.button.retry", "Try Again") }
    static var done: String { text("updater.button.done", "Done") }
    static var relaunch: String { text("updater.button.relaunch", "Relaunch") }
    static var releaseNotes: String { text("updater.button.releaseNotes", "Release Notes") }

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
