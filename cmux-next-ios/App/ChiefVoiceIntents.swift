import AppIntents
import CmuxChiefVoiceCore
import CmuxMobileChief
import CmuxMobileVoice

// App Intents for the iPhone Action Button, Siri, Spotlight, Shortcuts and the
// Shortcuts control in Control Center and on the Lock Screen
// (plans/cmux-next/ios-action-button-DESIGN.md). They live in the app target
// because App Intents metadata is extracted from the main bundle; each
// perform() is a one-line forward into ChiefVoice.

/// The app's one Chief call controller (the composition root names it once).
@MainActor
final class ChiefVoice {
    static let controller = ChiefVoiceController.live(sources: .shared)
}

/// Opens cmux into a live voice call with the user's Chief (Settings →
/// Chief Calls when no OpenAI API key is set). One button starts and stops:
/// pressing again with the call on screen hangs up; a minimized call comes back.
struct CallChiefIntent: AppIntent {
    static let title: LocalizedStringResource = "Call Chief"
    static let description = IntentDescription("Opens cmux and starts a live voice call with your Chief. Press again to hang up.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let call = ChiefLiveCall.shared
        if let session = call.session, !session.hasEnded, call.showsScreen {
            session.hangUp()
        } else {
            ChiefCallLauncher.shared.call()
        }
        return .result()
    }
}

/// Opens cmux and records a voice note for the user's Chief.
struct RecordChiefVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note for Chief"
    static let description = IntentDescription("Opens cmux and records a voice note. It is transcribed on this device and sent to your Chief.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await ChiefVoice.controller.handle(.voiceNote)
        return .result()
    }
}

/// The App Shortcuts the Action Button setting and Siri list for cmux.
struct CmuxMobileAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CallChiefIntent(),
            phrases: [
                "Call my Chief in \(.applicationName)",
                "Call Chief in \(.applicationName)",
                "Talk to my Chief in \(.applicationName)",
            ],
            shortTitle: "Call Chief",
            systemImageName: "phone.fill"
        )
        AppShortcut(
            intent: RecordChiefVoiceNoteIntent(),
            phrases: [
                "Record a voice note for my Chief in \(.applicationName)",
                "Voice note for Chief in \(.applicationName)",
            ],
            shortTitle: "Voice Note for Chief",
            systemImageName: "waveform"
        )
    }
}
