import AppKit
import CmuxSettings
import DynamicNotchKit
import Foundation
import SwiftUI

@MainActor
private final class DynamicNotchPointerMonitor {
    private let moved: (CGPoint) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(moved: @escaping (CGPoint) -> Void) {
        self.moved = moved
    }

    func start() {
        guard localMonitor == nil, globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.moved(NSEvent.mouseLocation)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.moved(NSEvent.mouseLocation)
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}

@MainActor
private final class DynamicNotchEscapeMonitor {
    private let pressed: () -> Bool
    private var localMonitor: Any?

    init(pressed: @escaping () -> Bool) {
        self.pressed = pressed
    }

    func start() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard event.keyCode == 53,
                  self?.pressed() == true else {
                return event
            }
            return nil
        }
    }

    func stop() {
        guard let localMonitor else { return }
        NSEvent.removeMonitor(localMonitor)
        self.localMonitor = nil
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }
}

/// Owns one accumulated menu-bar notification surface and maps each row's
/// controls back to the existing navigation and read-state paths.
@MainActor
final class DynamicNotchNotificationPresenter: NSObject, NSWindowDelegate {
    static let windowIdentifier = "cmux.dynamicNotchNotification"

    typealias Sleep = @Sendable (Duration) async throws -> Void
    private typealias Notch = DynamicNotch<
        DynamicNotchNotificationTrayView,
        DynamicNotchNotificationCompactLeadingView,
        DynamicNotchNotificationCompactTrailingView
    >

    private final class ActivePresentation {
        let model: DynamicNotchNotificationTrayModel
        let notch: Notch
        var selectedScreen: NSScreen?
        var pointerMonitor: DynamicNotchPointerMonitor?
        var escapeMonitor: DynamicNotchEscapeMonitor?
        var timeoutTasks: [UUID: Task<Void, Never>] = [:]
        var transitionTask: Task<Void, Never>?
        var arrivalRetractionTask: Task<Void, Never>?

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
    private let appearanceProvider: () -> DynamicNotchAppearance
    private let notificationCenter: NotificationCenter
    private var appearanceObserver: NSObjectProtocol?
    private var activePresentation: ActivePresentation?
    private var dismissalTransitions: [UUID: Task<Void, Never>] = [:]
#if DEBUG
    private var debugPhaseOverride: DynamicNotchNotificationPhase?
#endif

    init(
        openNotification: @escaping (TerminalNotification) -> Void,
        markRead: @escaping (UUID) -> Void,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        appearanceProvider: @escaping () -> DynamicNotchAppearance = {
            UserDefaultsSettingsClient(defaults: .standard).value(
                for: SettingCatalog().notifications.dynamicNotch
            )
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.openNotification = openNotification
        self.markRead = markRead
        self.sleep = sleep
        self.appearanceProvider = appearanceProvider
        self.notificationCenter = notificationCenter
        super.init()
        appearanceObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshGlobalAppearance()
            }
        }
    }

    deinit {
        if let appearanceObserver {
            notificationCenter.removeObserver(appearanceObserver)
        }
    }

    func apply(_ mutation: DynamicNotchNotificationMutation) {
        switch mutation {
        case .upsert(let notification, let superseding):
            upsert(notification, superseding: superseding)
        case .dismiss(let identifiers):
            dismiss(ids: identifiers)
        }
    }

    func present(_ notification: TerminalNotification) {
        upsert(notification, superseding: [])
    }

    func dismiss(id: UUID, responseAction: String = "dismissed") {
        resolve(
            id: id,
            responseAction: responseAction,
            values: [:]
        )
    }

    private func upsert(
        _ notification: TerminalNotification,
        superseding identifiers: Set<UUID>
    ) {
        if let activePresentation {
            guard activePresentation.model.notification(id: notification.id) == nil
                || identifiers.contains(notification.id) else {
                return
            }
            let animationDuration = Double(
                activePresentation.model.appearance(for: notification)
                    .dimension(.animationDuration)
            )
            let removed = withAnimation(.snappy(duration: animationDuration)) {
                activePresentation.model.upsert(
                    notification,
                    superseding: identifiers
                )
            }
            resolveSuperseded(removed, in: activePresentation)
            synchronizeAppearance(in: activePresentation)
            scheduleTimeout(for: notification, in: activePresentation)
            revealForArrival(in: activePresentation)
            return
        }

        let model = DynamicNotchNotificationTrayModel(
            globalAppearance: appearanceProvider()
        )
        model.upsert(notification, superseding: identifiers)

        let notch = DynamicNotch(
            hoverBehavior: [.keepVisible],
            style: .notch,
            chrome: model.trayAppearance.dynamicNotchChrome
        ) {
            DynamicNotchNotificationTrayView(
                model: model,
                performAction: { [weak self] action, values, selectedNotification in
                    self?.handleAction(
                        action,
                        values: values,
                        for: selectedNotification
                    )
                }
            )
        } compactLeading: {
            DynamicNotchNotificationCompactLeadingView(model: model)
        } compactTrailing: {
            DynamicNotchNotificationCompactTrailingView(model: model)
        }
        notch.transitionConfiguration.skipIntermediateHides = true
        notch.onWindowInitialized = { [weak self] window in
            self?.configureWindow(window)
        }

        let activePresentation = ActivePresentation(
            model: model,
            notch: notch
        )
        self.activePresentation = activePresentation

        notch.onHoverChanged = { [weak self, weak activePresentation] hovering in
            guard let self, let activePresentation else { return }
            self.handleHover(hovering, in: activePresentation)
        }
        let pointerMonitor = DynamicNotchPointerMonitor {
            [weak self, weak activePresentation] point in
            guard let self, let activePresentation else { return }
            self.handlePointerMoved(point, in: activePresentation)
        }
        activePresentation.pointerMonitor = pointerMonitor
        pointerMonitor.start()
        let escapeMonitor = DynamicNotchEscapeMonitor {
            [weak self, weak activePresentation] in
            guard let self, let activePresentation else { return false }
            return self.handleEscape(in: activePresentation)
        }
        activePresentation.escapeMonitor = escapeMonitor
        escapeMonitor.start()
        scheduleTimeout(for: notification, in: activePresentation)

        guard let fallbackScreen = NSScreen.screens.first else {
            close(activePresentation)
            return
        }
        let point = NSEvent.mouseLocation
        let nearbyScreen = screenNearNotch(
            for: point,
            appearance: model.trayAppearance
        )
        let screen = nearbyScreen ?? fallbackScreen
        activePresentation.selectedScreen = screen
        revealForArrival(in: activePresentation)
    }

    private func resolveSuperseded(
        _ notifications: [TerminalNotification],
        in activePresentation: ActivePresentation
    ) {
        for notification in notifications {
            activePresentation.timeoutTasks
                .removeValue(forKey: notification.id)?
                .cancel()
            writeResponse(
                action: "replaced",
                values: [:],
                notification: notification
            )
        }
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

    private func revealForArrival(
        in activePresentation: ActivePresentation
    ) {
#if DEBUG
        guard debugPhaseOverride == nil else { return }
#endif
        guard self.activePresentation === activePresentation,
              !activePresentation.notch.isHovering,
              activePresentation.model.phase != .expanded,
              let screen = activePresentation.selectedScreen
                ?? NSScreen.screens.first else {
            return
        }
        transition(
            to: .compact,
            on: screen,
            in: activePresentation
        )

        activePresentation.arrivalRetractionTask?.cancel()
        let duration = Double(
            activePresentation.model.trayAppearance
                .dimension(.arrivalRevealDuration)
        )
        activePresentation.arrivalRetractionTask = Task {
            @MainActor [weak self, weak activePresentation] in
            guard let self else { return }
            if duration > 0 {
                try? await self.sleep(.seconds(duration))
            }
            guard !Task.isCancelled,
                  let activePresentation,
                  self.activePresentation === activePresentation else {
                return
            }
            activePresentation.arrivalRetractionTask = nil
            self.handlePointerMoved(
                NSEvent.mouseLocation,
                in: activePresentation
            )
        }
    }

    private func handlePointerMoved(
        _ point: CGPoint,
        in activePresentation: ActivePresentation
    ) {
#if DEBUG
        guard debugPhaseOverride == nil else { return }
#endif
        guard self.activePresentation === activePresentation,
              !activePresentation.notch.isHovering else {
            return
        }
        let appearance = activePresentation.model.trayAppearance
        let nearbyScreen = screenNearNotch(
            for: point,
            appearance: appearance
        )
        let screen = nearbyScreen
            ?? activePresentation.selectedScreen
            ?? NSScreen.screens.first
        guard let screen else { return }
        if activePresentation.arrivalRetractionTask != nil {
            transition(
                to: .compact,
                on: screen,
                in: activePresentation
            )
            return
        }
        transition(
            to: idlePhase(
                isPointerNearby: nearbyScreen != nil,
                appearance: appearance
            ),
            on: screen,
            in: activePresentation
        )
    }

    private func handleHover(
        _ hovering: Bool,
        in activePresentation: ActivePresentation
    ) {
        guard self.activePresentation === activePresentation else { return }
#if DEBUG
        if debugPhaseOverride != nil {
            return
        }
#endif
        if hovering {
            guard let screen = activePresentation.notch.windowController?
                .window?.screen
                ?? activePresentation.selectedScreen
                ?? NSScreen.screens.first else {
                return
            }
            transition(
                to: .expanded,
                on: screen,
                in: activePresentation
            )
            if activePresentation.model.notifications.contains(
                where: { !$0.presentation.inputs.isEmpty }
            ) {
                activePresentation.notch.windowController?.window?.makeKey()
            }
        } else {
            if activePresentation.notch.windowController?.window?.isKeyWindow == true {
                activePresentation.notch.windowController?.window?.resignKey()
            }
            handlePointerMoved(
                NSEvent.mouseLocation,
                in: activePresentation
            )
        }
    }

    @discardableResult
    private func handleEscape(
        in activePresentation: ActivePresentation
    ) -> Bool {
        guard self.activePresentation === activePresentation,
              activePresentation.model.phase == .expanded else {
            return false
        }
#if DEBUG
        debugPhaseOverride = nil
#endif
        activePresentation.arrivalRetractionTask?.cancel()
        activePresentation.arrivalRetractionTask = nil

        let appearance = activePresentation.model.trayAppearance
        let nearbyScreen = screenNearNotch(
            for: NSEvent.mouseLocation,
            appearance: appearance
        )
        guard let screen = nearbyScreen
            ?? activePresentation.selectedScreen
            ?? NSScreen.screens.first else {
            return false
        }
        transition(
            to: idlePhase(
                isPointerNearby: nearbyScreen != nil,
                appearance: appearance
            ),
            on: screen,
            in: activePresentation
        )
        if activePresentation.notch.windowController?.window?.isKeyWindow == true {
            activePresentation.notch.windowController?.window?.resignKey()
        }
        return true
    }

    private func screenNearNotch(
        for point: CGPoint,
        appearance: DynamicNotchAppearance
    ) -> NSScreen? {
        let distance = appearance.dimension(.pointerRevealDistance)
        let syntheticWidth = appearance.dimension(.syntheticNotchWidth)
        return NSScreen.screens.first { screen in
            DynamicNotchScreenGeometry(
                screen: screen,
                syntheticNotchWidth: syntheticWidth
            ).isNearNotch(point, distance: distance)
        }
    }

    private func idlePhase(
        isPointerNearby: Bool,
        appearance: DynamicNotchAppearance
    ) -> DynamicNotchNotificationPhase {
        if !appearance.boolean(.retractWhenPointerLeaves) {
            return .compact
        }
        return isPointerNearby ? .compact : .retracted
    }

    private func transition(
        to phase: DynamicNotchNotificationPhase,
        on screen: NSScreen,
        in activePresentation: ActivePresentation
    ) {
        guard self.activePresentation === activePresentation,
              !activePresentation.model.notifications.isEmpty else {
            return
        }
        let screenChanged = !sameScreen(
            activePresentation.selectedScreen,
            screen
        )
        let windowMissing =
            activePresentation.notch.windowController?.window == nil
        guard activePresentation.model.phase != phase
                || screenChanged
                || windowMissing else {
            return
        }

        let animationDuration = Double(
            activePresentation.model.trayAppearance
                .dimension(.animationDuration)
        )
        withAnimation(.snappy(duration: animationDuration)) {
            activePresentation.model.transition(to: phase)
        }
        activePresentation.selectedScreen = screen
        activePresentation.transitionTask?.cancel()

        let notch = activePresentation.notch
        activePresentation.transitionTask = Task {
            @MainActor [weak self, weak activePresentation] in
            guard let self,
                  let activePresentation,
                  self.activePresentation === activePresentation,
                  !Task.isCancelled else {
                return
            }
            switch phase {
            case .retracted, .compact:
                await notch.compact(on: screen)
            case .expanded:
                await notch.expand(on: screen)
            }
            guard !Task.isCancelled,
                  self.activePresentation === activePresentation else {
                return
            }
            self.configureWindow(for: activePresentation)
            activePresentation.transitionTask = nil
        }
    }

    private func sameScreen(
        _ lhs: NSScreen?,
        _ rhs: NSScreen
    ) -> Bool {
        guard let lhs else { return false }
        if let lhsID = lhs.cmuxDisplayID,
           let rhsID = rhs.cmuxDisplayID {
            return lhsID == rhsID
        }
        return lhs.frame == rhs.frame
    }

    private func configureWindow(
        for activePresentation: ActivePresentation
    ) {
        guard let window = activePresentation.notch.windowController?.window else {
            return
        }
        configureWindow(window)
    }

    private func configureWindow(_ window: NSWindow) {
        window.identifier = NSUserInterfaceItemIdentifier(
            Self.windowIdentifier
        )
        window.delegate = self
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
        guard let activePresentation else {
            return nil
        }
        let removed = withAnimation {
            activePresentation.model.remove(id: id)
        }
        guard let notification = removed else { return nil }
        activePresentation.timeoutTasks.removeValue(forKey: id)?.cancel()
        writeResponse(
            action: responseAction,
            values: values,
            notification: notification
        )
        if activePresentation.model.notifications.isEmpty {
            close(activePresentation)
        } else {
            synchronizeAppearance(in: activePresentation)
        }
        return notification
    }

    private func dismiss(ids: Set<UUID>) {
        guard let activePresentation, !ids.isEmpty else { return }
        let notifications = withAnimation {
            activePresentation.model.remove(ids: ids)
        }
        for notification in notifications {
            activePresentation.timeoutTasks
                .removeValue(forKey: notification.id)?
                .cancel()
            writeResponse(
                action: "dismissed",
                values: [:],
                notification: notification
            )
        }
        if activePresentation.model.notifications.isEmpty {
            close(activePresentation)
        } else if !notifications.isEmpty {
            synchronizeAppearance(in: activePresentation)
        }
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
#if DEBUG
        debugPhaseOverride = nil
#endif
        activePresentation.pointerMonitor?.stop()
        activePresentation.pointerMonitor = nil
        activePresentation.escapeMonitor?.stop()
        activePresentation.escapeMonitor = nil
        activePresentation.transitionTask?.cancel()
        activePresentation.arrivalRetractionTask?.cancel()
        activePresentation.arrivalRetractionTask = nil
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

    private func refreshGlobalAppearance() {
        guard let activePresentation else { return }
        activePresentation.model.setGlobalAppearance(appearanceProvider())
        synchronizeAppearance(in: activePresentation)
        handlePointerMoved(
            NSEvent.mouseLocation,
            in: activePresentation
        )
    }

    private func synchronizeAppearance(
        in activePresentation: ActivePresentation
    ) {
        activePresentation.notch.chrome =
            activePresentation.model.trayAppearance.dynamicNotchChrome
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
            .appendingPathComponent(
                "cmux-notification-action-\(token.uuidString.lowercased()).json"
            )
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

#if DEBUG
    func debugSetPhase(_ rawPhase: String) -> Bool {
        guard let activePresentation else { return false }
        let normalized = rawPhase.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        if normalized == "auto" {
            debugPhaseOverride = nil
            handlePointerMoved(
                NSEvent.mouseLocation,
                in: activePresentation
            )
            return true
        }

        let phase: DynamicNotchNotificationPhase
        switch normalized {
        case "retracted":
            phase = .retracted
        case "compact":
            phase = .compact
        case "expanded":
            phase = .expanded
        default:
            return false
        }
        guard let screen = activePresentation.selectedScreen
            ?? NSScreen.screens.first else {
            return false
        }
        debugPhaseOverride = phase
        transition(
            to: phase,
            on: screen,
            in: activePresentation
        )
        return true
    }

    func debugSnapshot() -> [String: Any]? {
        guard let activePresentation else { return nil }
        let window = activePresentation.notch.windowController?.window
        let phase: String
        switch activePresentation.model.phase {
        case .retracted:
            phase = "retracted"
        case .compact:
            phase = "compact"
        case .expanded:
            phase = "expanded"
        }
        let override: String?
        switch debugPhaseOverride {
        case .retracted:
            override = "retracted"
        case .compact:
            override = "compact"
        case .expanded:
            override = "expanded"
        case nil:
            override = nil
        }
        var payload: [String: Any] = [
            "phase": phase,
            "notification_count": activePresentation.model.notifications.count,
            "notification_ids": activePresentation.model.notifications.map {
                $0.id.uuidString
            },
            "arrival_reveal_active":
                activePresentation.arrivalRetractionTask != nil,
            "is_hovering": activePresentation.notch.isHovering,
            "uses_synthetic_notch": activePresentation.notch.usesSyntheticNotch,
            "window_visible": window?.isVisible ?? false,
            "window_number": window?.windowNumber ?? 0,
            "window_identifier": window?.identifier?.rawValue ?? "",
        ]
        if let override {
            payload["phase_override"] = override
        }
        if let frame = window?.frame {
            payload["window_frame"] = [
                "x": frame.origin.x,
                "y": frame.origin.y,
                "width": frame.width,
                "height": frame.height,
            ]
        }
        if let screen = window?.screen ?? activePresentation.selectedScreen {
            payload["display_id"] = screen.cmuxDisplayID ?? 0
            payload["screen_frame"] = [
                "x": screen.frame.origin.x,
                "y": screen.frame.origin.y,
                "width": screen.frame.width,
                "height": screen.frame.height,
            ]
        }
        return payload
    }
#endif
}
