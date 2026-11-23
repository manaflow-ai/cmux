import Foundation

/// Strings of ``AppCopyGuide``: a second copy opened, and the move to Applications. Paths and versions are arguments.
extension UpdaterStrings {
    static var unknownVersion: String { text("updater.copy.unknownVersion", "unknown") }

    // A second copy was opened
    static var secondCopyTitle: String { text("updater.secondCopy.title", "Another Copy of cmux Was Opened") }
    static func secondCopyRunning(_ path: String, _ version: String) -> String {
        format("updater.secondCopy.running", "Still running: %1$@, version %2$@.", path, version)
    }
    static func secondCopyRunningGone(_ version: String, _ path: String) -> String {
        format("updater.secondCopy.runningGone", "Still running: version %1$@, which was moved or deleted from %2$@.", version, path)
    }
    static func secondCopyOpened(_ path: String, _ version: String) -> String {
        format("updater.secondCopy.opened", "You opened: %1$@, version %2$@.", path, version)
    }
    static var secondCopyOneAtATime: String {
        text("updater.secondCopy.oneAtATime", "Only one copy of cmux runs at a time, so the one already running stayed open.")
    }
    static var secondCopySwitchLine: String {
        text("updater.secondCopy.switchLine", "Switch to the copy you opened? cmux quits this copy and opens that one.")
    }
    static var secondCopyKeep: String { text("updater.secondCopy.keep", "Keep This Copy") }
    static var secondCopySwitch: String { text("updater.secondCopy.switch", "Switch Copies") }

    // Move to Applications
    static var moveTitle: String { text("updater.move.title", "Move cmux to Applications?") }
    static var moveTranslocated: String {
        text("updater.move.translocated",
             "macOS runs this copy from a temporary read-only folder, so it can't update itself and is gone after a restart.")
    }
    static var moveDiskImage: String {
        text("updater.move.diskImage",
             "This copy runs from the disk image, so it can't update itself and stops working when the disk image is ejected.")
    }
    static func moveCopies(_ folder: String) -> String {
        format("updater.move.copies", "cmux copies itself to %@ and reopens from there.", folder)
    }
    static func moveReplaces(_ version: String, _ folder: String) -> String {
        format("updater.move.replaces",
               "An older copy (version %1$@) is in %2$@. cmux replaces it, puts the old copy in the Trash, and reopens from there.",
               version, folder)
    }
    static func moveOpensInstalled(_ version: String, _ folder: String) -> String {
        format("updater.move.opensInstalled", "Version %1$@ is already in %2$@. cmux quits this copy and opens that one.", version, folder)
    }
    static var moveEjects: String { text("updater.move.ejects", "The disk image is ejected after cmux reopens.") }
    static var moveButton: String { text("updater.move.button", "Move to Applications") }
    static var moveReplaceButton: String { text("updater.move.replaceButton", "Replace and Reopen") }
    static var moveOpenInstalledButton: String { text("updater.move.openInstalledButton", "Open That Copy") }
    static var moveNotNow: String { text("updater.move.notNow", "Not Now") }
    static var moveFailedTitle: String { text("updater.move.failedTitle", "Couldn't Move cmux") }
}
