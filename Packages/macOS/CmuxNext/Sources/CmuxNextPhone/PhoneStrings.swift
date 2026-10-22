import Foundation

/// The phone tab's user-facing strings (Localizable.xcstrings in this module).
struct PhoneStrings {
    static var noPhones: String {
        t("phone.noPhones", "No phones. Add an iOS simulator in Xcode or an Android emulator in Android Studio.")
    }
    static var noPhonesShort: String { t("phone.noPhonesShort", "No Phones") }
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
    static var shutDown: String { t("phone.shutDown", "Shut Down") }
    static var refresh: String { t("phone.refresh", "Refresh") }
    static var setUpSimulators: String { t("phone.setUpSimulators", "Set Up iPhone Simulators…") }
    static var bootingHint: String { t("phone.bootingHint", "Starting the phone. The first start can take a minute.") }
    static var shuttingDown: String { t("phone.shuttingDown", "Shutting down…") }
    static var unavailableHint: String {
        t("phone.unavailableHint", "This simulator needs an iOS version that is not installed. Pick another phone, or add it in Xcode > Settings > Components.")
    }

    // Errors in plain words (PhoneErrorText).
    static var somethingWentWrong: String { t("phone.error.generic", "Something went wrong. Try again. If it keeps happening, record it and send it to Chief.") }
    static var errorNeedsXcode: String { t("phone.error.needsXcode", "iPhone simulators need Xcode, Apple's free app. Open a phone tab to set it up.") }
    static var errorNeedsAndroidStudio: String {
        t("phone.error.needsAndroidStudio", "Android phones need Android Studio. Install it, create an emulator, then check again.")
    }
    static var errorUnknownPhone: String { t("phone.error.unknownPhone", "That phone is not on this Mac anymore. Pick another one.") }
    static var errorNotRunning: String { t("phone.error.notRunning", "This phone is turned off. Click Boot to start it.") }
    static var errorUnsupported: String { t("phone.error.unsupported", "This phone cannot do that yet.") }
    static var errorNotRecording: String { t("phone.error.notRecording", "No recording is running.") }
    static var errorAlreadyRecording: String { t("phone.error.alreadyRecording", "A recording is already running. Stop it first.") }
    static var errorOutsideScreen: String { t("phone.error.outsideScreen", "That point is outside the phone's screen.") }
    static var errorUnreadable: String { t("phone.error.unreadable", "cmux could not read the phone's answer. Try again.") }
    static var errorLicense: String { t("phone.error.license", "Xcode needs you to accept its license. Open Xcode once and click Agree.") }
    static var errorDiskFull: String { t("phone.error.diskFull", "Your Mac does not have enough free disk space. Free some space, then try again.") }
    static var errorRuntimeMissing: String {
        t("phone.error.runtimeMissing", "This simulator's iOS version is not installed. Pick another phone, or download it.")
    }
    static var errorNetwork: String { t("phone.error.network", "The download stopped. Check your internet connection, then try again.") }

    // The setup screen (PhoneSetupViewState).
    static var setupChecking: String { t("phone.setup.checking", "Checking this Mac…") }
    static var setupCheckAgain: String { t("phone.setup.checkAgain", "Check Again") }
    static var setupAutoCheck: String {
        t("phone.setup.autoCheck", "cmux checks again on its own when you come back to this window.")
    }
    static var setupInstallXcodeTitle: String { t("phone.setup.installXcode.title", "Install Xcode to use iPhone simulators") }
    static var setupInstallXcodeBody: String {
        t("phone.setup.installXcode.body", "cmux shows iPhone simulators from Xcode, Apple's free app for making iPhone apps. Get it from the Mac App Store. It is a big download (about 3 GB, and it needs about 15 GB of disk space), so it can take 30 minutes or more.")
    }
    static var setupCommandLineToolsNote: String {
        t("phone.setup.commandLineToolsNote", "This Mac has Apple's command line tools, but they do not include simulators. You still need the full Xcode app.")
    }
    static var setupOpenAppStore: String { t("phone.setup.openAppStore", "Open the App Store") }
    static var setupXcodeWebsite: String { t("phone.setup.xcodeWebsite", "Other Ways to Get Xcode") }
    static var setupFinishXcodeTitle: String { t("phone.setup.finishXcode.title", "Open Xcode once to finish its setup") }
    static var setupFinishXcodeBody: String {
        t("phone.setup.finishXcode.body", "Xcode is installed but has not been opened yet. Open it, click Agree on the license, and let it install its extra parts. When Xcode shows its welcome window, you can quit it and come back here.")
    }
    static var setupOpenXcode: String { t("phone.setup.openXcode", "Open Xcode") }
    static var setupDownloadTitle: String { t("phone.setup.download.title", "Download the iPhone simulator") }
    static var setupDownloadBody: String {
        t("phone.setup.download.body", "Xcode is ready, but the iPhone simulator is a separate download of about 8 GB. cmux can download it for you. You can keep working while it downloads.")
    }
    static var setupDownload: String { t("phone.setup.download", "Download (about 8 GB)") }
    static var setupCancel: String { t("phone.setup.cancel", "Cancel") }
    static var setupDownloadStarting: String { t("phone.setup.downloadStarting", "Starting the download…") }
    static var setupCreateTitle: String { t("phone.setup.create.title", "Create an iPhone") }
    static var setupCreateBody: String {
        t("phone.setup.create.body", "Everything is installed. Create a simulated iPhone to show here. It runs on your Mac, so you do not need a real phone.")
    }
    static var setupCreating: String { t("phone.setup.creating", "Creating and starting the iPhone…") }
    static var setupAndroidNote: String {
        t("phone.setup.androidNote", "Making an Android app? Install Android Studio and create an emulator. It shows up here too.")
    }
    static var setupGetAndroidStudio: String { t("phone.setup.getAndroidStudio", "Get Android Studio") }
    static var stepInstallXcode: String { t("phone.setup.step.installXcode", "Install Xcode") }
    static var stepFinishXcode: String { t("phone.setup.step.finishXcode", "Open Xcode once") }
    static var stepDownloadIOS: String { t("phone.setup.step.downloadIOS", "Download the iPhone simulator") }
    static var stepCreateIPhone: String { t("phone.setup.step.createIPhone", "Create an iPhone") }

    static func setupCreate(_ model: String) -> String {
        String(format: t("phone.setup.createNamed", "Create %@"), model)
    }

    static func setupDownloading(percent: Int) -> String {
        String(format: t("phone.setup.downloading", "Downloading the iPhone simulator… %lld%%"), percent)
    }

    static func saved(_ path: String) -> String {
        String(format: t("phone.saved", "Saved to %@"), path)
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
