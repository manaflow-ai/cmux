import SwiftUI

#if DEBUG
struct NotificationDebugMenuButtons: View {
    var body: some View {
        Toggle(
            String(
                localized: "debug.menu.notification.mode",
                defaultValue: "Notification Debug Mode"
            ),
            isOn: Binding(
                get: { NotificationDebugEmitter.shared.isModeEnabled },
                set: { NotificationDebugEmitter.shared.isModeEnabled = $0 }
            )
        )

        Menu(
            String(
                localized: "debug.menu.notification.emit",
                defaultValue: "Emit Notification"
            )
        ) {
            debugButton(
                "turn-complete",
                title: String(localized: "debug.menu.notification.turnComplete", defaultValue: "Turn Complete")
            )
            debugButton(
                "idle",
                title: String(localized: "debug.menu.notification.idle", defaultValue: "Idle Reminder")
            )
            debugButton(
                "needs-permission",
                title: String(localized: "debug.menu.notification.needsPermission", defaultValue: "Needs Permission")
            )
            debugButton(
                "error",
                title: String(localized: "debug.menu.notification.error", defaultValue: "Error")
            )
            debugButton("cli", title: String(localized: "debug.menu.notification.cli", defaultValue: "CLI"))
            debugButton(
                "cli-reply",
                title: String(localized: "debug.menu.notification.cliReply", defaultValue: "CLI Reply")
            )
            debugButton("osc", title: String(localized: "debug.menu.notification.osc", defaultValue: "OSC"))
            debugButton(
                "hook-failed",
                title: String(localized: "debug.menu.notification.hookFailed", defaultValue: "Hook Failed")
            )
            debugButton(
                "feed-permission",
                title: String(localized: "debug.menu.notification.feedPermission", defaultValue: "Feed Permission")
            )
            debugButton(
                "feed-exit-plan",
                title: String(localized: "debug.menu.notification.feedExitPlan", defaultValue: "Feed Exit Plan")
            )
            debugButton(
                "feed-question",
                title: String(localized: "debug.menu.notification.feedQuestion", defaultValue: "Feed Question")
            )
            debugButton(
                "feed-question-4opts",
                title: String(localized: "debug.menu.notification.feedQuestion4", defaultValue: "Feed Question (4 Options)")
            )
            debugButton(
                "feed-question-multiselect",
                title: String(localized: "debug.menu.notification.feedQuestionMultiSelect", defaultValue: "Feed Question (Multi-select)")
            )
            debugButton(
                "feed-question-multi",
                title: String(localized: "debug.menu.notification.feedQuestionMultiple", defaultValue: "Feed Question (Multiple)")
            )
            debugButton(
                "feed-question-many-options",
                title: String(localized: "debug.menu.notification.feedQuestionMany", defaultValue: "Feed Question (Many Options)")
            )
            Divider()
            debugButton(
                "all",
                title: String(localized: "debug.menu.notification.all", defaultValue: "Emit All")
            )
        }
    }

    private func debugButton(_ kind: String, title: String) -> some View {
        Button(title) {
            _ = NotificationDebugEmitter.shared.emit(kind: kind, forceBanner: false)
        }
    }
}
#endif
