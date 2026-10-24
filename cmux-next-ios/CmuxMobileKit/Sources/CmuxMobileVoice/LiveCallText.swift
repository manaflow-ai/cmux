import Foundation

/// Every user-facing string of the live call screen. Keys live in
/// Resources/Localizable.xcstrings with every language
/// `scripts/cmux-next/check-l10n.sh` lists.
// lint:allow namespace: the module's string table; each member is a catalog lookup with no owning type.
enum LiveCallText {
    static var minimize: String { String(localized: "chiefLive.minimize", defaultValue: "Minimize Call", bundle: .module) }
    static var interruptHint: String { String(localized: "chiefLive.interruptHint", defaultValue: "Stops Chief so you can talk", bundle: .module) }
    static var connecting: String { String(localized: "chiefLive.status.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var ended: String { String(localized: "chiefLive.status.ended", defaultValue: "Call ended", bundle: .module) }
    static var failed: String { String(localized: "chiefLive.status.failed", defaultValue: "Call failed", bundle: .module) }
    static var onHold: String { String(localized: "chiefLive.status.onHold", defaultValue: "On hold", bundle: .module) }
    static var listening: String { String(localized: "chiefLive.status.listening", defaultValue: "Listening…", bundle: .module) }
    static var speaking: String { String(localized: "chiefLive.status.speaking", defaultValue: "Speaking", bundle: .module) }
    static var thinking: String { String(localized: "chiefLive.status.thinking", defaultValue: "Thinking…", bundle: .module) }
    static var muted: String { String(localized: "chiefLive.status.muted", defaultValue: "Muted", bundle: .module) }
    static var yourTurn: String { String(localized: "chiefLive.status.yourTurn", defaultValue: "Go ahead", bundle: .module) }
    static var hint: String { String(localized: "chiefLive.hint", defaultValue: "Talk to Chief like a colleague. Ask what your agents are doing, or have Chief start work on your Macs.", bundle: .module) }
    static var typePlaceholder: String { String(localized: "chiefLive.typePlaceholder", defaultValue: "Type to Chief", bundle: .module) }
    static var send: String { String(localized: "chiefLive.button.send", defaultValue: "Send", bundle: .module) }
    static var tryAgain: String { String(localized: "chiefLive.button.tryAgain", defaultValue: "Try Again", bundle: .module) }
    static var openSettings: String { String(localized: "chiefLive.button.openSettings", defaultValue: "Open Settings", bundle: .module) }
    static var done: String { String(localized: "chiefLive.button.done", defaultValue: "Done", bundle: .module) }
    static var mute: String { String(localized: "chiefLive.button.mute", defaultValue: "Mute", bundle: .module) }
    static var speaker: String { String(localized: "chiefLive.button.speaker", defaultValue: "Speaker", bundle: .module) }
    static var keyboard: String { String(localized: "chiefLive.button.keyboard", defaultValue: "Keyboard", bundle: .module) }
    static var end: String { String(localized: "chiefLive.button.end", defaultValue: "End", bundle: .module) }
    static var on: String { String(localized: "chiefLive.value.on", defaultValue: "On", bundle: .module) }
    static var off: String { String(localized: "chiefLive.value.off", defaultValue: "Off", bundle: .module) }
    static var you: String { String(localized: "chiefLive.you", defaultValue: "You", bundle: .module) }
    static var pillTitle: String { String(localized: "chiefLive.pill.title", defaultValue: "Chief", bundle: .module) }
    static var pillAccessibility: String { String(localized: "chiefLive.pill.accessibility", defaultValue: "Call with Chief. Opens the call.", bundle: .module) }
    static var failMicrophone: String { String(localized: "chiefLive.fail.microphone", defaultValue: "cmux can’t use the microphone", bundle: .module) }
    static var failMicrophoneDetail: String { String(localized: "chiefLive.fail.microphoneDetail", defaultValue: "Allow microphone access for cmux in Settings to talk to Chief.", bundle: .module) }
    static var failKeyMissing: String { String(localized: "chiefLive.fail.keyMissing", defaultValue: "Add your OpenAI API key", bundle: .module) }
    static var failKeyRejected: String { String(localized: "chiefLive.fail.keyRejected", defaultValue: "OpenAI refused your API key", bundle: .module) }
    static var failKeyDetail: String { String(localized: "chiefLive.fail.keyDetail", defaultValue: "Chief calls use your own OpenAI API key. Add or replace it in Settings → Chief Calls.", bundle: .module) }
    static var failQuota: String { String(localized: "chiefLive.fail.quota", defaultValue: "Your OpenAI account hit a limit", bundle: .module) }
    static var failModel: String { String(localized: "chiefLive.fail.model", defaultValue: "This voice model isn’t available to your key", bundle: .module) }
    static var failRefused: String { String(localized: "chiefLive.fail.refused", defaultValue: "OpenAI couldn’t start the call", bundle: .module) }
    static var failNetwork: String { String(localized: "chiefLive.fail.network", defaultValue: "Couldn’t connect", bundle: .module) }
    static var failDropped: String { String(localized: "chiefLive.fail.dropped", defaultValue: "The call dropped", bundle: .module) }
    static var failDroppedDetail: String { String(localized: "chiefLive.fail.droppedDetail", defaultValue: "The connection to OpenAI was lost. Try again when you have a better connection.", bundle: .module) }
}
