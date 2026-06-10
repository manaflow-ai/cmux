import AppKit
import Bonsplit
import Carbon
import SwiftUI


enum KeyboardShortcutRecorderActivity {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityDidChange")
    static let stopAllNotification = Notification.Name("cmux.keyboardShortcutRecorderActivityStopAll")
    private static var activeRecorderCount = 0

    static var isAnyRecorderActive: Bool {
        activeRecorderCount > 0
    }

    static func beginRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        activeRecorderCount += 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func endRecording(center: NotificationCenter = .default) {
        guard activeRecorderCount > 0 else { return }
        let wasActive = isAnyRecorderActive
        activeRecorderCount -= 1
        if wasActive != isAnyRecorderActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

    static func stopAllRecording(center: NotificationCenter = .default) {
        let wasActive = isAnyRecorderActive
        center.post(name: stopAllNotification, object: nil)
        guard activeRecorderCount > 0 else { return }
        activeRecorderCount = 0
        if wasActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }

#if DEBUG
    static func resetForTesting(center: NotificationCenter = .default) {
        // Keep test isolation from broadcasting stop-all UI notifications into unrelated live windows.
        let wasActive = isAnyRecorderActive
        activeRecorderCount = 0
        if wasActive {
            center.post(name: didChangeNotification, object: nil)
        }
    }
#endif
}

struct ShortcutRecorderRejectedAttempt: Equatable {
    let reason: KeyboardShortcutSettings.ShortcutRecordingRejection
    let proposedShortcut: StoredShortcut?
}
