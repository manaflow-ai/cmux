import AppKit
import Carbon
import CmuxSettingsUI

/// Receives the user-visible actions a registered system-wide (Carbon) hotkey
/// fires. Injected into ``SystemWideHotkeyController`` so the controller no
/// longer reaches back through an `AppDelegate.shared` singleton; the app
/// delegate conforms and is set as the handler before the controller starts.
@MainActor
protocol SystemWideHotkeyActionHandling: AnyObject {
    func toggleApplicationVisibilityFromGlobalHotkey()
    func toggleGlobalSearchPaletteFromGlobalHotkey()
    func captureMainWindowVisibilityRestoreTargetsForApplicationHide()
}

/// Owns the process-wide Carbon `RegisterEventHotKey` registrations for the
/// system-wide cmux hotkeys (show/hide all windows, global search) and keeps
/// them in sync with the configured shortcuts. Constructed and owned by the app
/// delegate, which injects itself as the ``SystemWideHotkeyActionHandling``.
final class SystemWideHotkeyController {
    private static let hotKeySignature: OSType = 0x434D484B // "CMHK"
    private static let hotKeyIDs: [KeyboardShortcutSettings.Action: UInt32] = [
        .showHideAllWindows: 1,
        .globalSearch: 2,
    ]
    private static let systemWideActions: [KeyboardShortcutSettings.Action] = [
        .showHideAllWindows,
        .globalSearch,
    ]

    weak var actionHandler: (any SystemWideHotkeyActionHandling)?

    private var hotKeyRefs: [KeyboardShortcutSettings.Action: EventHotKeyRef] = [:]
    private var hotKeyHandler: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?
    private var shortcutObserver: NSObjectProtocol?
    private var recorderObserver: NSObjectProtocol?
    private var packageRecorderObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var registeredShortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var registeredHotKeyRegistrations: [KeyboardShortcutSettings.Action: CarbonHotKeyRegistration] = [:]

    init() {}

    func start() {
        guard defaultsObserver == nil else { return }

        installHotKeyHandlerIfNeeded()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        recorderObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutRecorderActivity.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        // The live Settings UI uses the CmuxSettingsUI package recorder, which
        // signals arm/disarm through its own notification (it cannot post the
        // app-target `KeyboardShortcutRecorderActivity` one). Without this,
        // recording a system-wide hotkey in Settings would not unregister the
        // existing Carbon hotkey, so the keystroke would fire the global action
        // instead of being captured (issue #5189).
        packageRecorderObserver = NotificationCenter.default.addObserver(
            forName: RecorderHostButton.activeRecordingDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshRegistration()
        }
        appHideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureHiddenWindowRestoreTargets()
            }
        }

        refreshRegistration()
    }

    private func refreshRegistration() {
        // Stand down while either recorder is armed (legacy app-target recorder
        // or the CmuxSettingsUI package recorder) so a system-wide hotkey being
        // rebound in Settings is captured rather than fired.
        let isShortcutRecordingActive = KeyboardShortcutRecorderActivity.isAnyRecorderActive
            || RecorderHostButton.isActivelyRecording

        guard !isShortcutRecordingActive else {
            unregisterHotKeys()
            return
        }

        for action in Self.systemWideActions {
            refreshRegistration(for: action)
        }
    }

    private func refreshRegistration(for action: KeyboardShortcutSettings.Action) {
        let configuredShortcut = shortcut(for: action)
        guard isSystemWideActionEnabled(action, shortcut: configuredShortcut) else {
            unregisterHotKey(for: action)
            return
        }

        guard let normalizedShortcut = action.normalizedRecordedShortcut(configuredShortcut),
              let registration = normalizedShortcut.carbonHotKeyRegistration else {
            unregisterHotKey(for: action)
            return
        }

        if registeredShortcuts[action] == normalizedShortcut,
           registeredHotKeyRegistrations[action] == registration,
           hotKeyRefs[action] != nil {
            return
        }

        unregisterHotKey(for: action)
        installHotKeyHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID(for: action))
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            registration.keyCode,
            registration.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
#if DEBUG
            cmuxDebugLog(
                "globalHotkey.register failed action=\(action.rawValue) shortcut=\(normalizedShortcut.displayString) " +
                "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers) status=\(status)"
            )
#endif
            return
        }

        hotKeyRefs[action] = hotKeyRef
        registeredShortcuts[action] = normalizedShortcut
        registeredHotKeyRegistrations[action] = registration

#if DEBUG
        cmuxDebugLog(
            "globalHotkey.register success action=\(action.rawValue) shortcut=\(normalizedShortcut.displayString) " +
            "keyCode=\(registration.keyCode) modifiers=\(registration.modifiers)"
        )
#endif
    }

    private func shortcut(for action: KeyboardShortcutSettings.Action) -> StoredShortcut {
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.shortcut()
        default:
            return KeyboardShortcutSettings.shortcut(for: action)
        }
    }

    private func isSystemWideActionEnabled(
        _ action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.isEnabled()
        case .globalSearch:
            return true
        default:
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            return false
        }
    }

    private func installHotKeyHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            userInfo,
            &hotKeyHandler
        )

#if DEBUG
        if status != noErr {
            cmuxDebugLog("globalHotkey.handlerInstall failed status=\(status)")
        }
#endif
    }

    private func unregisterHotKey(for action: KeyboardShortcutSettings.Action) {
        if let hotKeyRef = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(hotKeyRef)
        }
        registeredShortcuts[action] = nil
        registeredHotKeyRegistrations[action] = nil
    }

    private func unregisterHotKeys() {
        for action in Self.systemWideActions {
            unregisterHotKey(for: action)
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userInfo in
        guard let userInfo else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<SystemWideHotkeyController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return controller.handleHotKeyEvent(event)
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              let action = Self.action(forHotKeyID: hotKeyID.id) else {
            return OSStatus(eventNotHandledErr)
        }

#if DEBUG
        let shortcut = registeredShortcuts[action]?.displayString ?? "unknown"
        cmuxDebugLog("globalHotkey.fire action=\(action.rawValue) shortcut=\(shortcut) active=\(NSApp.isActive ? 1 : 0)")
#endif

        Task { @MainActor [weak self] in
            self?.perform(action)
        }
        return OSStatus(noErr)
    }

    @MainActor
    private func perform(_ action: KeyboardShortcutSettings.Action) {
        switch action {
        case .showHideAllWindows:
            actionHandler?.toggleApplicationVisibilityFromGlobalHotkey()
        case .globalSearch:
            actionHandler?.toggleGlobalSearchPaletteFromGlobalHotkey()
        default:
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            break
        }
    }

    @MainActor
    private func captureHiddenWindowRestoreTargets() {
        actionHandler?.captureMainWindowVisibilityRestoreTargetsForApplicationHide()
    }

    private static func hotKeyID(for action: KeyboardShortcutSettings.Action) -> UInt32 {
        guard let hotKeyID = hotKeyIDs[action] else {
            assertionFailure("Unhandled system-wide hotkey action: \(action.rawValue)")
            return 0
        }
        return hotKeyID
    }

    private static func action(forHotKeyID hotKeyID: UInt32) -> KeyboardShortcutSettings.Action? {
        systemWideActions.first { Self.hotKeyID(for: $0) == hotKeyID }
    }
}
