import Foundation

/// The phone tab's user-facing strings (Localizable.xcstrings in this module).
struct PhoneStrings {
    static var noPhones: String {
        t("phone.noPhones", "No phones. Add an iOS simulator in Xcode or an Android emulator in Android Studio.")
    }
    static var realDevice: String { t("phone.realDevice", "Device") }
    static var boot: String { t("phone.boot", "Boot") }
    static var booting: String { t("phone.booting", "Booting…") }
    static var screenshot: String { t("phone.screenshot", "Screenshot") }
    static var record: String { t("phone.record", "Record") }
    static var stop: String { t("phone.stop", "Stop") }
    static var sendToChief: String { t("phone.sendToChief", "Send to Chief") }
    static var sent: String { t("phone.sent", "Sent to Chief.") }
    static var notesPlaceholder: String { t("phone.notes", "What went wrong?") }
    static var screenLabel: String { t("phone.screenLabel", "Phone screen") }
    static var recordingHint: String { t("phone.recordingHint", "Recording the screen, your inputs and the device log.") }
    static var shutDownHint: String { t("phone.shutDownHint", "This phone is shut down. Boot it to see its screen.") }
    static var stillFrameHint: String { t("phone.stillFrame", "The screen updates after each action.") }

    static func saved(_ path: String) -> String {
        String(format: t("phone.saved", "Saved to %@"), path)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
