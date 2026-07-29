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
                self?.pressed() == true
            else {
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

/// Owns one accumulated notification queue mirrored into an independently
/// interactive Dynamic Notch surface on every connected display.
@MainActor
final class DynamicNotchNotificationPresenter: NSObject, NSWindowDelegate {
    static let windowIdentifier = "cmux.dynamicNotchNotification"

    typealias Sleep = @Sendable (Duration) async throws -> Void
    private typealias Notch = DynamicNotch<
        DynamicNotchNotificationTrayView,
        DynamicNotchNotificationCompactLeadingView,
        DynamicNotchNotificationCompactTrailingView
    >

    private final class DisplayPresentation {
        let displayKey: String
        var screen: NSScreen
        let model: DynamicNotchNotificationTrayModel
        let notch: Notch
        var transitionTask: Task<Void, Never>?
        var arrivalRetractionTask: Task<Void, Never>?

        init(
            displayKey: String,
            screen: NSScreen,
            model: DynamicNotchNotificationTrayModel,
            notch: Notch
        ) {
            self.displayKey = displayKey
            self.screen = screen
            self.model = model
            self.notch = notch
        }
    }

    private final class ActivePresentation {
        /// Canonical queue. Display models mirror its notifications while
        /// retaining an independent phase and horizontal position.
        let model: DynamicNotchNotificationTrayModel
        var displays: [String: DisplayPresentation] = [:]
        var pointerMonitor: DynamicNotchPointerMonitor?
        var escapeMonitor: DynamicNotchEscapeMonitor?
        var timeoutTasks: [UUID: Task<Void, Never>] = [:]

        init(model: DynamicNotchNotificationTrayModel) {
            self.model = model
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
    private let displayPositionsProvider: () -> [String: String]
    private let deliveryModeProvider: () -> NotificationDeliveryMode
    private let screensProvider: () -> [NSScreen]
    private let notificationCenter: NotificationCenter
    private var appearanceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var activePresentation: ActivePresentation?
    private var dismissalTransitions: [UUID: Task<Void, Never>] = [:]
    #if DEBUG
        private var debugPhaseOverride: DynamicNotchNotificationPhase?
    #endif

    init(
        openNotification: @escaping (TerminalNotification) -> Void,
        markRead: @escaping (UUID) -> Void,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        appearanceProvider: @escaping () -> DynamicNotchAppearance = {
            UserDefaultsSettingsClient(defaults: .standard).value(
                for: SettingCatalog().notifications.dynamicNotch
            )
        },
        displayPositionsProvider: @escaping () -> [String: String] = {
            UserDefaultsSettingsClient(defaults: .standard).value(
                for: SettingCatalog().notifications
                    .dynamicNotchDisplayPositions
            )
        },
        deliveryModeProvider: @escaping () -> NotificationDeliveryMode = {
            UserDefaultsSettingsClient(defaults: .standard).value(
                for: SettingCatalog().notifications.delivery
            )
        },
        screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
        notificationCenter: NotificationCenter = .default
    ) {
        self.openNotification = openNotification
        self.markRead = markRead
        self.sleep = sleep
        self.appearanceProvider = appearanceProvider
        self.displayPositionsProvider = displayPositionsProvider
        self.deliveryModeProvider = deliveryModeProvider
        self.screensProvider = screensProvider
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
        screenObserver = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenParametersDidChange()
            }
        }
    }

    deinit {
        if let appearanceObserver {
            notificationCenter.removeObserver(appearanceObserver)
        }
        if let screenObserver {
            notificationCenter.removeObserver(screenObserver)
        }
    }

    func apply(_ mutation: DynamicNotchNotificationMutation) {
        switch mutation {
        case .upsert(let notification):
            upsert(notification)
        case .dismiss(let identifiers):
            dismiss(ids: identifiers)
        }
    }

    func present(_ notification: TerminalNotification) {
        upsert(notification)
    }

    func dismiss(id: UUID, responseAction: String = "dismissed") {
        resolve(id: id, responseAction: responseAction, values: [:])
    }

    private func upsert(_ notification: TerminalNotification) {
        if let activePresentation {
            let duration = Double(
                activePresentation.model.appearance(for: notification)
                    .dimension(.animationDuration)
            )
            activePresentation.model.upsert(notification)
            for display in activePresentation.displays.values {
                withAnimation(.snappy(duration: duration)) {
                    display.model.upsert(notification)
                }
            }
            reconcileDisplays(in: activePresentation, revealNewDisplays: false)
            synchronizeAppearance(in: activePresentation)
            scheduleTimeout(for: notification, in: activePresentation)
            for display in activePresentation.displays.values {
                revealForArrival(display, in: activePresentation)
            }
            return
        }

        let canonicalModel = DynamicNotchNotificationTrayModel(
            globalAppearance: appearanceProvider()
        )
        canonicalModel.upsert(notification)
        let activePresentation = ActivePresentation(model: canonicalModel)
        self.activePresentation = activePresentation

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

        reconcileDisplays(in: activePresentation, revealNewDisplays: false)
        scheduleTimeout(for: notification, in: activePresentation)
        for display in activePresentation.displays.values {
            revealForArrival(display, in: activePresentation)
        }
    }

    private func makeDisplayPresentation(
        for screen: NSScreen,
        in activePresentation: ActivePresentation
    ) -> DisplayPresentation {
        let displayKey = screen.cmuxDynamicNotchDisplayKey
        let model = DynamicNotchNotificationTrayModel(
            globalAppearance: appearanceProvider(),
            displayHorizontalPosition: displayPosition(for: displayKey)
        )
        for notification in activePresentation.model.notifications.reversed() {
            model.enqueue(notification)
        }

        let notch = DynamicNotch(
            hoverBehavior: [.keepVisible],
            style: .notch,
            chrome: model.trayAppearance.dynamicNotchChrome
        ) {
            DynamicNotchNotificationTrayView(
                model: model,
                performAction: {
                    [weak self] action, values, selectedNotification in
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

        let display = DisplayPresentation(
            displayKey: displayKey,
            screen: screen,
            model: model,
            notch: notch
        )
        notch.allowsSyntheticNotchDragging = true
        notch.onSyntheticNotchHorizontalPositionChanged = {
            [weak self, weak activePresentation, weak display] position in
            guard let self, let activePresentation, let display else { return }
            self.persistSyntheticNotchPosition(
                Double(position),
                for: display,
                in: activePresentation
            )
        }
        notch.onHoverChanged = {
            [weak self, weak activePresentation, weak display] hovering in
            guard let self, let activePresentation, let display else { return }
            self.handleHover(
                hovering,
                on: display,
                in: activePresentation
            )
        }
        return display
    }

    private func reconcileDisplays(
        in activePresentation: ActivePresentation,
        revealNewDisplays: Bool
    ) {
        guard self.activePresentation === activePresentation else { return }
        let screens = screensProvider()
        let currentScreens = Dictionary(
            screens.map { ($0.cmuxDynamicNotchDisplayKey, $0) },
            uniquingKeysWith: { _, newest in newest }
        )

        for displayKey in activePresentation.displays.keys
        where currentScreens[displayKey] == nil {
            guard
                let removed = activePresentation.displays
                    .removeValue(forKey: displayKey)
            else {
                continue
            }
            retire(removed)
        }

        for screen in screens {
            let displayKey = screen.cmuxDynamicNotchDisplayKey
            if let display = activePresentation.displays[displayKey] {
                display.screen = screen
                display.model.setGlobalAppearance(appearanceProvider())
                display.model.setDisplayHorizontalPosition(
                    displayPosition(for: displayKey)
                )
                synchronizeAppearance(for: display)
                display.notch.refreshScreenGeometry(on: screen)
                continue
            }

            let display = makeDisplayPresentation(
                for: screen,
                in: activePresentation
            )
            activePresentation.displays[displayKey] = display
            #if DEBUG
                if let debugPhaseOverride {
                    transition(
                        to: debugPhaseOverride,
                        on: display,
                        in: activePresentation
                    )
                    continue
                }
            #endif
            if revealNewDisplays {
                revealForArrival(display, in: activePresentation)
            }
        }
    }

    private func screenParametersDidChange() {
        guard let activePresentation else { return }
        reconcileDisplays(in: activePresentation, revealNewDisplays: true)
        handlePointerMoved(NSEvent.mouseLocation, in: activePresentation)
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
                activePresentation.model.notification(
                    id: notification.id
                ) != nil
            else {
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
        _ display: DisplayPresentation,
        in activePresentation: ActivePresentation
    ) {
        #if DEBUG
            guard debugPhaseOverride == nil else { return }
        #endif
        guard isActive(display, in: activePresentation),
            !display.notch.isHovering,
            display.model.phase != .expanded
        else {
            return
        }
        transition(to: .compact, on: display, in: activePresentation)

        display.arrivalRetractionTask?.cancel()
        let duration = Double(
            display.model.trayAppearance.dimension(.arrivalRevealDuration)
        )
        display.arrivalRetractionTask = Task {
            @MainActor [weak self, weak activePresentation, weak display] in
            guard let self else { return }
            if duration > 0 {
                try? await self.sleep(.seconds(duration))
            }
            guard !Task.isCancelled,
                let activePresentation,
                let display,
                self.isActive(display, in: activePresentation)
            else {
                return
            }
            display.arrivalRetractionTask = nil
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
        guard self.activePresentation === activePresentation else { return }
        for display in activePresentation.displays.values {
            guard !display.notch.isHovering else { continue }
            if display.arrivalRetractionTask != nil {
                transition(to: .compact, on: display, in: activePresentation)
                continue
            }
            let appearance = display.model.trayAppearance
            transition(
                to: idlePhase(
                    isPointerNearby: isPointer(
                        point,
                        near: display.screen,
                        appearance: appearance
                    ),
                    appearance: appearance
                ),
                on: display,
                in: activePresentation
            )
        }
    }

    private func handleHover(
        _ hovering: Bool,
        on display: DisplayPresentation,
        in activePresentation: ActivePresentation
    ) {
        guard isActive(display, in: activePresentation) else { return }
        #if DEBUG
            if debugPhaseOverride != nil {
                return
            }
        #endif
        if hovering {
            transition(to: .expanded, on: display, in: activePresentation)
            if display.model.notifications.contains(
                where: { !$0.presentation.inputs.isEmpty }
            ) {
                display.notch.windowController?.window?.makeKey()
            }
        } else {
            if display.notch.windowController?.window?.isKeyWindow == true {
                display.notch.windowController?.window?.resignKey()
            }
            handlePointerMoved(NSEvent.mouseLocation, in: activePresentation)
        }
    }

    @discardableResult
    private func handleEscape(
        in activePresentation: ActivePresentation
    ) -> Bool {
        guard self.activePresentation === activePresentation else {
            return false
        }
        let expandedDisplays = activePresentation.displays.values.filter {
            $0.model.phase == .expanded
        }
        guard !expandedDisplays.isEmpty else { return false }
        #if DEBUG
            debugPhaseOverride = nil
        #endif
        let point = NSEvent.mouseLocation
        for display in expandedDisplays {
            display.arrivalRetractionTask?.cancel()
            display.arrivalRetractionTask = nil
            let appearance = display.model.trayAppearance
            transition(
                to: idlePhase(
                    isPointerNearby: isPointer(
                        point,
                        near: display.screen,
                        appearance: appearance
                    ),
                    appearance: appearance
                ),
                on: display,
                in: activePresentation
            )
            if display.notch.windowController?.window?.isKeyWindow == true {
                display.notch.windowController?.window?.resignKey()
            }
        }
        return true
    }

    private func isPointer(
        _ point: CGPoint,
        near screen: NSScreen,
        appearance: DynamicNotchAppearance
    ) -> Bool {
        DynamicNotchScreenGeometry(
            screen: screen,
            syntheticNotchWidth: appearance.dimension(.syntheticNotchWidth),
            syntheticNotchSafeAreaWidth:
                appearance.dynamicNotchHorizontalSafeWidth,
            syntheticNotchHorizontalPosition: appearance.dimension(
                .syntheticNotchHorizontalPosition
            )
        ).isNearNotch(
            point,
            distance: appearance.dimension(.pointerRevealDistance)
        )
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
        on display: DisplayPresentation,
        in activePresentation: ActivePresentation
    ) {
        guard isActive(display, in: activePresentation),
            !display.model.notifications.isEmpty
        else {
            return
        }
        let windowMissing = display.notch.windowController?.window == nil
        guard display.model.phase != phase || windowMissing else { return }

        let duration = Double(
            display.model.trayAppearance.dimension(.animationDuration)
        )
        withAnimation(.snappy(duration: duration)) {
            display.model.transition(to: phase)
        }
        display.transitionTask?.cancel()

        let notch = display.notch
        let screen = display.screen
        display.transitionTask = Task {
            @MainActor [weak self, weak activePresentation, weak display] in
            guard let self,
                let activePresentation,
                let display,
                self.isActive(display, in: activePresentation),
                !Task.isCancelled
            else {
                return
            }
            switch phase {
            case .retracted, .compact:
                await notch.compact(on: screen)
            case .expanded:
                await notch.expand(on: screen)
            }
            guard !Task.isCancelled,
                self.isActive(display, in: activePresentation)
            else {
                return
            }
            self.configureWindow(for: display)
            display.transitionTask = nil
        }
    }

    private func isActive(
        _ display: DisplayPresentation,
        in activePresentation: ActivePresentation
    ) -> Bool {
        self.activePresentation === activePresentation
            && activePresentation.displays[display.displayKey] === display
    }

    private func configureWindow(for display: DisplayPresentation) {
        guard let window = display.notch.windowController?.window else {
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
        guard
            let resolvedNotification = resolve(
                id: notification.id,
                responseAction: action,
                values: values
            )
        else {
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
            let notification = activePresentation.model.remove(id: id)
        else {
            return nil
        }
        for display in activePresentation.displays.values {
            withAnimation {
                display.model.remove(id: id)
            }
        }
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

    private func dismiss(
        ids: Set<UUID>,
        responseAction: String = "dismissed"
    ) {
        guard let activePresentation, !ids.isEmpty else { return }
        let notifications = activePresentation.model.remove(ids: ids)
        guard !notifications.isEmpty else { return }
        for display in activePresentation.displays.values {
            withAnimation {
                display.model.remove(ids: ids)
            }
        }
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
        if activePresentation.model.notifications.isEmpty {
            close(activePresentation)
        } else {
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
        activePresentation.timeoutTasks.values.forEach { $0.cancel() }
        activePresentation.timeoutTasks.removeAll()
        let displays = Array(activePresentation.displays.values)
        activePresentation.displays.removeAll()
        displays.forEach(retire)
    }

    private func retire(_ display: DisplayPresentation) {
        display.transitionTask?.cancel()
        display.transitionTask = nil
        display.arrivalRetractionTask?.cancel()
        display.arrivalRetractionTask = nil
        if display.notch.windowController?.window?.isKeyWindow == true {
            display.notch.windowController?.window?.resignKey()
        }

        let transitionID = UUID()
        let notch = display.notch
        let task = Task { @MainActor [weak self] in
            await notch.hide()
            self?.dismissalTransitions[transitionID] = nil
        }
        dismissalTransitions[transitionID] = task
    }

    private func refreshGlobalAppearance() {
        guard let activePresentation else { return }
        if deliveryModeProvider() != .dynamicNotch {
            let settingsDeliveredIDs = Set(
                activePresentation.model.notifications
                    .filter { $0.presentation.delivery == .settings }
                    .map(\.id)
            )
            dismiss(
                ids: settingsDeliveredIDs,
                responseAction: "delivery_changed"
            )
            guard self.activePresentation === activePresentation else {
                return
            }
        }
        activePresentation.model.setGlobalAppearance(appearanceProvider())
        reconcileDisplays(in: activePresentation, revealNewDisplays: false)
        synchronizeAppearance(in: activePresentation)
        handlePointerMoved(NSEvent.mouseLocation, in: activePresentation)
    }

    private func displayPosition(for displayKey: String) -> Double? {
        DynamicNotchDisplayPositionSettings.position(
            for: displayKey,
            in: displayPositionsProvider()
        )
    }

    private func persistSyntheticNotchPosition(
        _ position: Double,
        for display: DisplayPresentation,
        in activePresentation: ActivePresentation
    ) {
        guard isActive(display, in: activePresentation) else { return }
        let settings = UserDefaultsSettingsClient(defaults: .standard)
        let key = SettingCatalog().notifications.dynamicNotchDisplayPositions
        let updated = DynamicNotchDisplayPositionSettings.setting(
            position,
            for: display.displayKey,
            in: settings.value(for: key)
        )
        settings.set(updated, for: key)
        display.model.setDisplayHorizontalPosition(position)
        synchronizeAppearance(for: display)
    }

    private func synchronizeAppearance(
        in activePresentation: ActivePresentation
    ) {
        for display in activePresentation.displays.values {
            synchronizeAppearance(for: display)
        }
    }

    private func synchronizeAppearance(for display: DisplayPresentation) {
        display.notch.chrome = display.model.trayAppearance.dynamicNotchChrome
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let activePresentation,
            activePresentation.displays.values.contains(where: {
                $0.notch.windowController?.window === sender
            })
        else {
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
            guard let activePresentation,
                !activePresentation.displays.isEmpty
            else {
                return false
            }
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
            debugPhaseOverride = phase
            for display in activePresentation.displays.values {
                transition(to: phase, on: display, in: activePresentation)
            }
            return true
        }

        func debugSnapshot() -> [String: Any]? {
            guard let activePresentation else { return nil }
            let displays = activePresentation.displays.values
                .sorted { $0.displayKey < $1.displayKey }
            guard let primary = displays.first else { return nil }
            let window = primary.notch.windowController?.window
            var payload: [String: Any] = [
                "phase": phaseName(primary.model.phase),
                "notification_count":
                    activePresentation.model.notifications.count,
                "notification_ids":
                    activePresentation.model.notifications.map {
                        $0.id.uuidString
                    },
                "display_count": displays.count,
                "displays": displays.map(displayDebugPayload),
                "arrival_reveal_active":
                    displays.contains { $0.arrivalRetractionTask != nil },
                "is_hovering":
                    displays.contains { $0.notch.isHovering },
                "uses_synthetic_notch": primary.notch.usesSyntheticNotch,
                "window_visible": window?.isVisible ?? false,
                "window_number": window?.windowNumber ?? 0,
                "window_identifier": window?.identifier?.rawValue ?? "",
            ]
            if let debugPhaseOverride {
                payload["phase_override"] = phaseName(debugPhaseOverride)
            }
            if let frame = window?.frame {
                payload["window_frame"] = rectPayload(frame)
            }
            payload["display_id"] = primary.screen.cmuxDisplayID ?? 0
            payload["screen_frame"] = rectPayload(primary.screen.frame)
            return payload
        }

        private func displayDebugPayload(
            _ display: DisplayPresentation
        ) -> [String: Any] {
            let window = display.notch.windowController?.window
            let position = display.model.trayAppearance.dimension(
                .syntheticNotchHorizontalPosition
            )
            return [
                "display_key": display.displayKey,
                "display_id": display.screen.cmuxDisplayID ?? 0,
                "display_name": display.screen.localizedName,
                "phase": phaseName(display.model.phase),
                "horizontal_position": Double(position),
                "has_position_override":
                    display.model.displayHorizontalPosition != nil,
                "uses_synthetic_notch": display.notch.usesSyntheticNotch,
                "window_visible": window?.isVisible ?? false,
                "window_number": window?.windowNumber ?? 0,
                "window_frame": rectPayload(window?.frame ?? .zero),
                "screen_frame": rectPayload(display.screen.frame),
            ]
        }

        private func phaseName(
            _ phase: DynamicNotchNotificationPhase
        ) -> String {
            switch phase {
            case .retracted:
                "retracted"
            case .compact:
                "compact"
            case .expanded:
                "expanded"
            }
        }

        private func rectPayload(_ rect: CGRect) -> [String: Double] {
            [
                "x": Double(rect.origin.x),
                "y": Double(rect.origin.y),
                "width": Double(rect.width),
                "height": Double(rect.height),
            ]
        }
    #endif
}
