import Foundation

/// What the notification sound actions say (the NotificationsPanel table).
nonisolated enum NotificationSoundStrings {
    static func unsupportedFile(_ name: String) -> String {
        String(localized: "notifications.sound.refusal.unsupported",
               defaultValue: "\(name) is not a sound file cmux can play (AIFF, CAF, WAV, MP3 or M4A).",
               bundle: .module)
    }

    static func importFailed(_ name: String) -> String {
        String(localized: "notifications.sound.refusal.importFailed", defaultValue: "Could not copy \(name) to ~/Library/Sounds.",
               bundle: .module)
    }

    static var chooseMessage: String {
        String(localized: "notifications.sound.choose.message", defaultValue: "Choose a sound for notifications. cmux copies it to ~/Library/Sounds.",
               bundle: .module)
    }

    static var choosePrompt: String {
        String(localized: "notifications.sound.choose.prompt", defaultValue: "Use Sound", bundle: .module)
    }

    static var silent: String {
        String(localized: "notifications.sound.refusal.silent", defaultValue: "Notifications here play no sound: a level above mutes them.",
               bundle: .module)
    }

    static var noAgent: String {
        String(localized: "notifications.sound.refusal.noAgent", defaultValue: "Name the agent kind, for example agent=claude.",
               bundle: .module)
    }

    static var needsSound: String {
        String(localized: "notifications.sound.refusal.needsSound", defaultValue: "Name a sound, a volume or a file, for example sound=Glass.",
               bundle: .module)
    }

    static var noEvent: String {
        String(localized: "notifications.sound.refusal.noEvent",
               defaultValue: "Name the event: finished, needsInput, error, bell or message.", bundle: .module)
    }
}
