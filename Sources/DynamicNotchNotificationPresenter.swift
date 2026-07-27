import AppKit
import DynamicNotchKit
import Foundation
import SwiftUI

/// Owns the current DynamicNotchKit panel and maps its controls back to the
/// existing notification navigation and read-state paths.
@MainActor
final class DynamicNotchNotificationPresenter: NSObject, NSWindowDelegate {
    static let windowIdentifier = "cmux.dynamicNotchNotification"

    typealias Sleep = @Sendable (Duration) async throws -> Void

    private final class ActivePresentation {
        let notification: TerminalNotification
        let notch: DynamicNotch<DynamicNotchNotificationView, EmptyView, EmptyView>
        var timeoutTask: Task<Void, Never>?
        var transitionTask: Task<Void, Never>?

        init(
            notification: TerminalNotification,
            notch: DynamicNotch<DynamicNotchNotificationView, EmptyView, EmptyView>
        ) {
            self.notification = notification
            self.notch = notch
        }
    }

    private struct DismissalTransition {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct ActionResponse: Encodable {
        let action: String
        let notificationId: UUID
        let values: [String: String]

        enum CodingKeys: String, CodingKey {
            case action
            case notificationId = "notification_id"
            case values
        }
    }

    private let openNotification: (TerminalNotification) -> Void
    private let markRead: (UUID) -> Void
    private let sleep: Sleep
    private var activePresentation: ActivePresentation?
    private var dismissalTransitions: [UUID: DismissalTransition] = [:]

    init(
        openNotification: @escaping (TerminalNotification) -> Void,
        markRead: @escaping (UUID) -> Void,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.openNotification = openNotification
        self.markRead = markRead
        self.sleep = sleep
        super.init()
    }

    func present(_ notification: TerminalNotification) {
        dismissActivePanel(responseAction: "replaced")

        let notch = DynamicNotch(
            hoverBehavior: [.increaseShadow],
            style: .auto
        ) { [weak self] in
            DynamicNotchNotificationView(notification: notification) { action, values in
                self?.handleAction(action, values: values, for: notification)
            }
        }

        let activePresentation = ActivePresentation(
            notification: notification,
            notch: notch
        )
        self.activePresentation = activePresentation

        if notification.presentation.timeout > 0 {
            let timeout = notification.presentation.timeout
            activePresentation.timeoutTask = Task { @MainActor [weak self, weak activePresentation] in
                guard let self else { return }
                try? await self.sleep(.seconds(timeout))
                guard !Task.isCancelled,
                      let activePresentation,
                      self.activePresentation === activePresentation else {
                    return
                }
                self.dismiss(id: notification.id, responseAction: "timeout")
            }
        }

        activePresentation.transitionTask = Task { @MainActor [weak self, weak activePresentation] in
            guard let self,
                  !Task.isCancelled,
                  let activePresentation,
                  self.activePresentation === activePresentation,
                  let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            await notch.expand(on: screen)
            guard !Task.isCancelled,
                  self.activePresentation === activePresentation else {
                return
            }
            notch.windowController?.window?.identifier = NSUserInterfaceItemIdentifier(
                Self.windowIdentifier
            )
            notch.windowController?.window?.delegate = self
            if !notification.presentation.inputs.isEmpty {
                notch.windowController?.window?.makeKey()
            }
            activePresentation.transitionTask = nil
        }
    }

    func dismiss(id: UUID, responseAction: String = "dismissed") {
        guard activePresentation?.notification.id == id else { return }
        dismissActivePanel(responseAction: responseAction)
    }

    private func handleAction(
        _ action: String,
        values: [String: String],
        for notification: TerminalNotification
    ) {
        guard activePresentation?.notification.id == notification.id else { return }
        // Resolve the interactive response before mutating the store. Marking a
        // notification read synchronously asks this presenter to dismiss it,
        // which would otherwise overwrite the selected action with "dismissed".
        dismissActivePanel(responseAction: action, values: values)
        switch action {
        case "open":
            openNotification(notification)
        case "dismiss":
            break
        default:
            markRead(notification.id)
        }
    }

    private func dismissActivePanel(
        responseAction: String,
        values: [String: String] = [:]
    ) {
        guard let activePresentation else { return }
        self.activePresentation = nil
        activePresentation.timeoutTask?.cancel()
        activePresentation.transitionTask?.cancel()
        writeResponse(
            action: responseAction,
            values: values,
            notification: activePresentation.notification
        )
        let notificationID = activePresentation.notification.id
        let notch = activePresentation.notch
        dismissalTransitions[notificationID]?.task.cancel()
        let transitionToken = UUID()
        let task = Task { @MainActor [weak self] in
            await notch.hide()
            guard let self,
                  self.dismissalTransitions[notificationID]?.token == transitionToken else {
                return
            }
            self.dismissalTransitions[notificationID] = nil
        }
        dismissalTransitions[notificationID] = DismissalTransition(
            token: transitionToken,
            task: task
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let activePresentation,
              activePresentation.notch.windowController?.window === sender else {
            return true
        }
        dismissActivePanel(responseAction: "dismissed")
        return false
    }

    private func writeResponse(
        action: String,
        values: [String: String],
        notification: TerminalNotification
    ) {
        guard let token = notification.presentation.responseToken else { return }
        let response = ActionResponse(
            action: action,
            notificationId: notification.id,
            values: values
        )
        guard let data = try? JSONEncoder().encode(response) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-action-\(token.uuidString.lowercased()).json")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
    }
}
