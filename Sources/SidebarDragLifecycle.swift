import AppKit
import CmuxSocketControl
import Bonsplit
import Combine
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebarProviderKit
import CmuxExtensionSidebarExamples
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI
import CmuxUpdater
import CmuxUpdaterUI
import ImageIO
import Observation
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

enum SidebarDragLifecycleNotification {
    static let stateDidChange = Notification.Name("cmux.sidebarDragStateDidChange")
    static let requestClear = Notification.Name("cmux.sidebarDragRequestClear")
    static let tabIdKey = "tabId"
    static let reasonKey = "reason"

    static func postStateDidChange(tabId: UUID?, reason: String) {
        var userInfo: [AnyHashable: Any] = [reasonKey: reason]
        if let tabId {
            userInfo[tabIdKey] = tabId
        }
        NotificationCenter.default.post(
            name: stateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    static func postClearRequest(reason: String) {
        NotificationCenter.default.post(
            name: requestClear,
            object: nil,
            userInfo: [reasonKey: reason]
        )
    }

    static func tabId(from notification: Notification) -> UUID? {
        notification.userInfo?[tabIdKey] as? UUID
    }

    static func reason(from notification: Notification) -> String {
        notification.userInfo?[reasonKey] as? String ?? "unknown"
    }
}

enum SidebarOutsideDropResetPolicy {
    static func shouldResetDrag(draggedTabId: UUID?, hasSidebarDragPayload: Bool) -> Bool {
        draggedTabId != nil && hasSidebarDragPayload
    }
}

enum SidebarDragFailsafePolicy {
    static let clearDelay: TimeInterval = 0.15

    static func shouldRequestClear(isDragActive: Bool, isLeftMouseButtonDown: Bool) -> Bool {
        isDragActive && !isLeftMouseButtonDown
    }

    static func shouldRequestClearWhenMonitoringStarts(isLeftMouseButtonDown: Bool) -> Bool {
        shouldRequestClear(
            isDragActive: true,
            isLeftMouseButtonDown: isLeftMouseButtonDown
        )
    }

    static func shouldRequestClear(forMouseEventType eventType: NSEvent.EventType) -> Bool {
        eventType == .leftMouseUp
    }
}

@MainActor
final class SidebarDragFailsafeMonitor: ObservableObject {
    private static let escapeKeyCode: UInt16 = 53
    private var pendingClearWorkItem: DispatchWorkItem?
    private var appResignObserver: NSObjectProtocol?
    private var keyDownMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var onRequestClear: ((String) -> Void)?

    func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy.shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy.shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    func stop() {
        pendingClearWorkItem?.cancel()
        pendingClearWorkItem = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearWorkItem == nil else { return }
#if DEBUG
        cmuxDebugLog("sidebar.dragFailsafe.schedule reason=\(reason)")
#endif
        let workItem = DispatchWorkItem { [weak self] in
#if DEBUG
            cmuxDebugLog("sidebar.dragFailsafe.fire reason=\(reason)")
#endif
            self?.pendingClearWorkItem = nil
            self?.onRequestClear?(reason)
        }
        pendingClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarDragFailsafePolicy.clearDelay, execute: workItem)
    }
}

struct SidebarExternalDropOverlay: View {
    let draggedTabId: UUID?

    var body: some View {
        let dragPasteboardTypes = NSPasteboard(name: .drag).types
        let shouldCapture = DragOverlayRoutingPolicy.shouldCaptureSidebarExternalOverlay(
            draggedTabId: draggedTabId,
            pasteboardTypes: dragPasteboardTypes
        )
        Group {
            if shouldCapture {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .onDrop(
                        of: SidebarTabDragPayload.dropContentTypes,
                        delegate: SidebarExternalDropDelegate(draggedTabId: draggedTabId)
                    )
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct SidebarExternalDropDelegate: DropDelegate {
    let draggedTabId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        let hasSidebarPayload = info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
        let shouldReset = SidebarOutsideDropResetPolicy.shouldResetDrag(
            draggedTabId: draggedTabId,
            hasSidebarDragPayload: hasSidebarPayload
        )
#if DEBUG
        cmuxDebugLog(
            "sidebar.dropOutside.validate tab=\(debugShortSidebarTabId(draggedTabId)) " +
            "hasType=\(hasSidebarPayload) allowed=\(shouldReset)"
        )
#endif
        return shouldReset
    }

    func dropEntered(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.entered tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropExited(info: DropInfo) {
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.exited tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.updated tab=\(debugShortSidebarTabId(draggedTabId)) op=move")
#endif
        // Explicit move proposal avoids AppKit showing a copy (+) cursor.
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
#if DEBUG
        cmuxDebugLog("sidebar.dropOutside.perform tab=\(debugShortSidebarTabId(draggedTabId))")
#endif
        SidebarDragLifecycleNotification.postClearRequest(reason: "outside_sidebar_drop")
        return true
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}

enum ShortcutHintModifierActivation {
    case commandOrControl
    case commandOnly
    case controlOnly

    func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch self {
        case .commandOrControl:
            return ShortcutHintModifierPolicy.shouldShowHints(for: modifierFlags, defaults: defaults)
        case .commandOnly:
            return ShortcutHintModifierPolicy.shouldShowCommandHints(for: modifierFlags, defaults: defaults)
        case .controlOnly:
            return ShortcutHintModifierPolicy.shouldShowControlHints(for: modifierFlags, defaults: defaults)
        }
    }
}

@MainActor
@Observable
final class WindowScopedShortcutHintModifierMonitor {
    private(set) var isModifierPressed = false

    private let activation: ShortcutHintModifierActivation
    private let allowsHintsForWindow: (NSWindow) -> Bool
    @ObservationIgnored private weak var hostWindow: NSWindow?
    @ObservationIgnored private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    @ObservationIgnored private var flagsMonitor: Any?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var appResignObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingShowWorkItem: DispatchWorkItem?

    init(
        activation: ShortcutHintModifierActivation = .commandOrControl,
        allowsHintsForWindow: @escaping (NSWindow) -> Bool = { _ in true }
    ) {
        self.activation = activation
        self.allowsHintsForWindow = allowsHintsForWindow
    }

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }

        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isCurrentWindow(eventWindow: event.window) else { return }
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        ShortcutHintModifierPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard let hostWindow,
              isCurrentWindow(eventWindow: eventWindow),
              allowsHintsForWindow(hostWindow),
              activation.shouldShowHints(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        queueHintShow()
    }

    private func queueHintShow() {
        guard !isModifierPressed else { return }
        guard pendingShowWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            guard let hostWindow = self.hostWindow,
                  self.isCurrentWindow(eventWindow: nil),
                  self.allowsHintsForWindow(hostWindow),
                  self.activation.shouldShowHints(for: NSEvent.modifierFlags) else {
                return
            }
            self.isModifierPressed = true
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ShortcutHintModifierPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        if resetVisible, isModifierPressed {
            isModifierPressed = false
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}
