import Foundation

/// Every user-facing string of the Chief call screen. Keys live in
/// Resources/Localizable.xcstrings with every language
/// `scripts/cmux-next/check-l10n.sh` lists.
// lint:allow namespace: the module's string table; each member is a catalog lookup with no owning type.
enum VoiceText {
    static var callTitle: String { String(localized: "chiefCall.title.call", defaultValue: "Chief", bundle: .module) }
    static var voiceNoteTitle: String { String(localized: "chiefCall.title.voiceNote", defaultValue: "Voice Note for Chief", bundle: .module) }
    static var askingMicrophone: String { String(localized: "chiefCall.status.askingMicrophone", defaultValue: "Waiting for microphone access…", bundle: .module) }
    static var microphoneDenied: String { String(localized: "chiefCall.status.microphoneDenied", defaultValue: "cmux can’t use the microphone. Allow it in Settings to talk to your Chief.", bundle: .module) }
    static var recording: String { String(localized: "chiefCall.status.recording", defaultValue: "Recording. Your Chief gets this when you hang up.", bundle: .module) }
    static var saving: String { String(localized: "chiefCall.status.saving", defaultValue: "Saving…", bundle: .module) }
    static var transcribing: String { String(localized: "chiefCall.status.transcribing", defaultValue: "Transcribing…", bundle: .module) }
    static var sending: String { String(localized: "chiefCall.status.sending", defaultValue: "Sending to Chief…", bundle: .module) }
    static var sent: String { String(localized: "chiefCall.status.sent", defaultValue: "Sent to Chief.", bundle: .module) }
    static var savedForLater: String { String(localized: "chiefCall.status.savedForLater", defaultValue: "Saved. It sends when your Chief is reachable.", bundle: .module) }
    static var failed: String { String(localized: "chiefCall.status.failed", defaultValue: "Recording couldn’t start.", bundle: .module) }
    static var endButton: String { String(localized: "chiefCall.button.end", defaultValue: "End", bundle: .module) }
    static var doneButton: String { String(localized: "chiefCall.button.done", defaultValue: "Done", bundle: .module) }
    static var openSettingsButton: String { String(localized: "chiefCall.button.openSettings", defaultValue: "Open Settings", bundle: .module) }
    static func noTranscript(seconds: Int) -> String { String(localized: "chiefCall.noTranscript", defaultValue: "Voice note (\(seconds) s), no transcript", bundle: .module) }
}
