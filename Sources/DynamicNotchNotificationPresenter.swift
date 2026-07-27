import AppKit
import DynamicNotchKit
import Foundation
import SwiftUI

/// Owns the accumulated Dynamic Notch tray and maps each row's controls back
/// to the existing notification navigation and read-state paths.
@MainActor
final class DynamicNotchNotificationPresenter: NSObject, NSWindowDelegate {
    static let windowIdentifier = "cmux.dynamicNotchNotification"

    typealias Sleep = @Sendable (Duration) async throws -> Void
    private typealias Notch = DynamicNotch<
        DynamicNotchNotificationTrayView,
        EmptyView,
        EmptyView
    >

    private final class ActivePresentation {
        let model: DynamicNotchNotificationTrayModel
        let notch: Notch
        var timeoutTasks: [UUID: Task<Void, Never>] = [:]
        var transitionTask: Task<Void, Never>?

        init(
            model: DynamicNotchNotificationTrayModel,
            notch: Notch
        ) {
            self.model = model
            self.notch = notch
        }
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
    private var dismissalTransitions: [UUID: Task<Void, Never>] = [:]

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
        if let activePresentation {
            guard activePresentation.model.enqueue(notification) else { return }
            scheduleTimeout(for: notification, in: activePresentation)
            return
        }

        let model = DynamicNotchNotificationTrayModel()
        guard model.enqueue(notification) else { return }

        let notch = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto
        ) {
            DynamicNotchNotificationTrayView(
                model: model,
                hoverChanged: { [weak self, weak model] hovering in
                    guard let model else { return }
                    self?.handleHover(hovering, model: model)
                },
                performAction: { [weak self] action, values, selectedNotification in
                    self?.handleAction(
                        action,
                        values: values,
                        for: selectedNotification
                    )
                }
            )
        }

        let activePresentation = ActivePresentation(
            model: model,
            notch: notch
        )
        self.activePresentation = activePresentation
        scheduleTimeout(for: notification, in: activePresentation)

        activePresentation.transitionTask = Task {
            @MainActor [weak self, weak activePresentation] in
            guard let self,
                  !Task.isCancelled,
                  let activePresentation,
                  self.activePresentation === activePresentation,
                  let screen = NSScreen.main ?? NSScreen.screens.first else {
                return
            }
            await notch.expand(on: screen)
            guard !Task.isCancelled,
                  self.activePresentation === activePresentation else {
                return
            }
            notch.windowController?.window?.identifier = NSUserInterfaceItemIdentifier(
                Self.windowIdentifier
            )
            notch.windowController?.window?.delegate = self
            activePresentation.transitionTask = nil
        }
    }

    func dismiss(id: UUID, responseAction: String = "dismissed") {
        resolve(
            id: id,
            responseAction: responseAction,
            values: [:]
        )
    }

    private func scheduleTimeout(
        for notification: TerminalNotification,
        in activePresentation: ActivePresentation
    ) {
        guard notification.presentation.timeout > 0 else { return }
        activePresentation.timeoutTasks[notification.id]?.cancel()
        let timeout = notification.presentation.timeout
        activePresentation.timeoutTasks[notification.id] = Task {
            @MainActor [weak self, weak activePresentation] in
            guard let self else { return }
            try? await self.sleep(.seconds(timeout))
            guard !Task.isCancelled,
                  let activePresentation,
                  self.activePresentation === activePresentation,
                  activePresentation.model.notification(id: notification.id) != nil else {
                return
            }
            self.resolve(
                id: notification.id,
                responseAction: "timeout",
                values: [:]
            )
        }
    }

    private func handleHover(
        _ hovering: Bool,
        model: DynamicNotchNotificationTrayModel
    ) {
        guard let activePresentation,
              activePresentation.model === model,
              let window = activePresentation.notch.windowController?.window else {
            return
        }
        if hovering,
           model.notifications.contains(where: { !$0.presentation.inputs.isEmpty }) {
            window.makeKey()
        } else if !hovering, window.isKeyWindow {
            window.resignKey()
        }
    }

    private func handleAction(
        _ action: String,
        values: [String: String],
        for notification: TerminalNotification
    ) {
        guard let resolvedNotification = resolve(
            id: notification.id,
            responseAction: action,
            values: values
        ) else {
            return
        }
        switch action {
        case "open":
            openNotification(resolvedNotification)
        case "dismiss":
            break
        default:
            markRead(resolvedNotification.id)
        }
    }

    @discardableResult
    private func resolve(
        id: UUID,
        responseAction: String,
        values: [String: String]
    ) -> TerminalNotification? {
        guard let activePresentation,
              let notification = activePresentation.model.remove(id: id) else {
            return nil
        }
        activePresentation.timeoutTasks.removeValue(forKey: id)?.cancel()
        writeResponse(
            action: responseAction,
            values: values,
            notification: notification
        )
        if activePresentation.model.notifications.isEmpty {
            close(activePresentation)
        }
        return notification
    }

    private func dismissAll(responseAction: String) {
        guard let activePresentation else { return }
        let notifications = activePresentation.model.removeAll()
        for notification in notifications {
            activePresentation.timeoutTasks
                .removeValue(forKey: notification.id)?
                .cancel()
            writeResponse(
                action: responseAction,
                values: [:],
                notification: notification
            )
        }
        close(activePresentation)
    }

    private func close(_ activePresentation: ActivePresentation) {
        guard self.activePresentation === activePresentation else { return }
        self.activePresentation = nil
        activePresentation.transitionTask?.cancel()
        activePresentation.timeoutTasks.values.forEach { $0.cancel() }
        activePresentation.timeoutTasks.removeAll()
        if activePresentation.notch.windowController?.window?.isKeyWindow == true {
            activePresentation.notch.windowController?.window?.resignKey()
        }

        let transitionID = UUID()
        let notch = activePresentation.notch
        let task = Task { @MainActor [weak self] in
            await notch.hide()
            self?.dismissalTransitions[transitionID] = nil
        }
        dismissalTransitions[transitionID] = task
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let activePresentation,
              activePresentation.notch.windowController?.window === sender else {
            return true
        }
        dismissAll(responseAction: "dismissed")
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
