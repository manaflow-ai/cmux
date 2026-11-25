import Foundation

/// What the notification sound actions say (the NotificationsPanel table).
nonisolated enum NotificationSoundStrings {
    static func unsupportedFile(_ name: String) -> String {
        String(localized: "notifications.sound.refusal.unsupported",
               defaultValue: "\(name) is not a sound file cmux can play (AIFF, CAF, WAV, MP3 or M4A).",
               bundle: .localizedModule)
    }

    static func importFailed(_ name: String) -> String {
        String(localized: "notifications.sound.refusal.copyFailed", defaultValue: "Could not copy \(name) into cmux's sounds folder.",
               bundle: .localizedModule)
    }

    static var chooseMessage: String {
        String(localized: "notifications.sound.choose.keepsCopy", defaultValue: "Choose a sound for notifications. cmux keeps its own copy.",
               bundle: .localizedModule)
    }

    static var choosePrompt: String {
        String(localized: "notifications.sound.choose.prompt", defaultValue: "Use Sound", bundle: .localizedModule)
    }

    static var silent: String {
        String(localized: "notifications.sound.refusal.silent", defaultValue: "Notifications here play no sound: a level above mutes them.",
               bundle: .localizedModule)
    }

    static var noAgent: String {
        String(localized: "notifications.sound.refusal.noAgent", defaultValue: "Name the agent kind, for example agent=claude.",
               bundle: .localizedModule)
    }

    static var needsSound: String {
        String(localized: "notifications.sound.refusal.needsSound", defaultValue: "Name a sound, a volume or a file, for example sound=Glass.",
               bundle: .localizedModule)
    }

    static var noEvent: String {
        String(localized: "notifications.sound.refusal.noEvent",
               defaultValue: "Name the event: finished, needsInput, error, bell or message.", bundle: .localizedModule)
    }
}
