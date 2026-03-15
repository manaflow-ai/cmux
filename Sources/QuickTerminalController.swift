import AppKit
import Carbon
import SwiftUI

/// Manages the quick terminal (quake/visor mode) window.
///
/// The quick terminal is a floating, borderless window that slides down from
/// the top of the screen (or another configured edge) when toggled via a global
/// hotkey. Unlike Ghostty's quick terminal, cmux's version hosts a full
/// ContentView with sidebar and tabs.
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate {

    // MARK: - Types

    enum Position: String, Sendable {
        case top
        case bottom
        case left
        case right
        case center
    }

    struct QuickTerminalKeybind: Equatable, Sendable {
        var keyCode: UInt16?
        var characters: String?
        var commandModifier: Bool
        var shiftModifier: Bool
        var optionModifier: Bool
        var controlModifier: Bool

        var modifierFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if commandModifier { flags.insert(.command) }
            if shiftModifier { flags.insert(.shift) }
            if optionModifier { flags.insert(.option) }
            if controlModifier { flags.insert(.control) }
            return flags
        }
    }

    // MARK: - Configuration

    private(set) var position: Position = .top
    private(set) var animationDuration: TimeInterval = 0.15
    private(set) var screenFraction: CGFloat = 0.5

    // MARK: - State

    private var window: NSWindow?
    private var tabManager: TabManager?
    private var sidebarState: SidebarState?
    private var sidebarSelectionState: SidebarSelectionState?
    private var isVisible = false
    private var isAnimating = false
    private var lastFrame: NSRect?
    private(set) var windowId: UUID?

    // MARK: - Global Hotkey

    private var carbonHotkeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var localMonitor: Any?

    /// The keybind parsed from Ghostty config (e.g. "super+grave_accent").
    /// When nil, the quick terminal feature is disabled.
    private(set) var keybind: QuickTerminalKeybind?

    // MARK: - Singleton

    static let shared = QuickTerminalController()
    private override init() {
        super.init()
    }

    // MARK: - Setup

    private var didLoadConfiguration = false

    /// Load quick terminal settings from the Ghostty config files via
    /// the shared `GhosttyConfig` parser (same file search order and
    /// parsing logic used for all other Ghostty settings in cmux).
    func loadConfiguration() {
        guard !didLoadConfiguration else { return }
        didLoadConfiguration = true

        let config = GhosttyConfig.load(useCache: false)

        if let raw = config.quickTerminalKeybindRaw {
            keybind = Self.parseKeybind(raw)
        }
        if let p = config.quickTerminalPosition, let pos = Position(rawValue: p) {
            position = pos
        }
        if let d = config.quickTerminalAnimationDuration {
            animationDuration = d
        }
        if let f = config.quickTerminalScreenFraction {
            screenFraction = max(0.1, min(1.0, CGFloat(f)))
        }
    }

    /// Parse a Ghostty keybind line like "global:super+grave_accent=toggle_quick_terminal".
    nonisolated static func parseKeybind(_ value: String) -> QuickTerminalKeybind? {
        // Must end with toggle_quick_terminal action
        let bindParts = value.split(separator: "=", maxSplits: 1)
        guard bindParts.count == 2 else { return nil }
        let action = bindParts[1].trimmingCharacters(in: .whitespaces)
        guard action == "toggle_quick_terminal" else { return nil }

        var keyPart = bindParts[0].trimmingCharacters(in: .whitespaces)

        // Must be a global keybind
        guard keyPart.hasPrefix("global:") else { return nil }
        keyPart = String(keyPart.dropFirst("global:".count))

        // Parse modifier+key combinations
        let tokens = keyPart.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty else { return nil }

        var hasCommand = false
        var hasShift = false
        var hasOption = false
        var hasControl = false
        var keyName: String?

        for token in tokens {
            switch token {
            case "super", "cmd", "command":
                hasCommand = true
            case "shift":
                hasShift = true
            case "alt", "opt", "option":
                hasOption = true
            case "ctrl", "control":
                hasControl = true
            default:
                keyName = token
            }
        }

        guard let key = keyName else { return nil }

        return QuickTerminalKeybind(
            keyCode: ghosttyKeyNameToKeyCode(key),
            characters: ghosttyKeyNameToCharacters(key),
            commandModifier: hasCommand,
            shiftModifier: hasShift,
            optionModifier: hasOption,
            controlModifier: hasControl
        )
    }

    nonisolated private static func ghosttyKeyNameToKeyCode(_ name: String) -> UInt16? {
        switch name {
        case "grave_accent", "backquote", "`": return 50
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "space": return 49
        case "tab": return 48
        case "return", "enter": return 36
        case "escape": return 53
        case "minus", "-": return 27
        case "equal", "=": return 24
        case "left_bracket", "[": return 33
        case "right_bracket", "]": return 30
        case "backslash", "\\": return 42
        case "semicolon", ";": return 41
        case "apostrophe", "'": return 39
        case "comma", ",": return 43
        case "period", ".": return 47
        case "slash", "/": return 44
        default: return nil
        }
    }

    nonisolated private static func ghosttyKeyNameToCharacters(_ name: String) -> String? {
        switch name {
        case "grave_accent", "backquote", "`": return "`"
        case "space": return " "
        case "tab": return "\t"
        case "return", "enter": return "\r"
        default:
            if name.count == 1 { return name }
            return nil
        }
    }

    // MARK: - Event Matching (nonisolated for use in monitor callbacks)

    nonisolated private static func eventMatchesKeybind(_ event: NSEvent, _ bind: QuickTerminalKeybind) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        guard flags == bind.modifierFlags else { return false }

        if let expectedCode = bind.keyCode {
            return event.keyCode == expectedCode
        }
        if let expectedChars = bind.characters {
            return event.charactersIgnoringModifiers?.lowercased() == expectedChars
        }
        return false
    }

    // MARK: - Global Hotkey Management

    /// Carbon modifier flags from our keybind.
    nonisolated private static func carbonModifiers(for bind: QuickTerminalKeybind) -> UInt32 {
        var mods: UInt32 = 0
        if bind.commandModifier { mods |= UInt32(cmdKey) }
        if bind.shiftModifier { mods |= UInt32(shiftKey) }
        if bind.optionModifier { mods |= UInt32(optionKey) }
        if bind.controlModifier { mods |= UInt32(controlKey) }
        return mods
    }

    func installGlobalHotkey() {
        guard let bind = keybind, let keyCode = bind.keyCode else { return }

        // Register a Carbon global hotkey — works system-wide without Accessibility permissions.
        let hotkeyID = EventHotKeyID(signature: OSType(0x636D7578), id: 1) // "cmux"
        let modifiers = Self.carbonModifiers(for: bind)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerCallback: EventHandlerUPP = { _, event, _ -> OSStatus in
            DispatchQueue.main.async {
                QuickTerminalController.shared.toggle()
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            handlerCallback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        carbonHandlerRef = handlerRef

        var hotkeyRef: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        carbonHotkeyRef = hotkeyRef

        // Local monitor: catches the hotkey when the app IS active (Carbon global
        // hotkeys don't fire for the owning app's own key events).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.eventMatchesKeybind(event, bind) {
                Self.shared.toggle()
                return nil
            }
            return event
        }
    }

    func removeGlobalHotkey() {
        if let ref = carbonHotkeyRef {
            UnregisterEventHotKey(ref)
            carbonHotkeyRef = nil
        }
        if let ref = carbonHandlerRef {
            RemoveEventHandler(ref)
            carbonHandlerRef = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Toggle

    func toggle() {
        guard !isAnimating else { return }

        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Show

    private func show() {
        let win = window ?? createQuickTerminalWindow()
        window = win

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let targetFrame = lastFrame ?? quickTerminalFrame(in: visibleFrame)

        // Set initial off-screen frame for slide animation
        var startFrame = targetFrame
        switch position {
        case .top:
            startFrame.origin.y = visibleFrame.maxY
        case .bottom:
            startFrame.origin.y = visibleFrame.minY - targetFrame.height
        case .left:
            startFrame.origin.x = visibleFrame.minX - targetFrame.width
        case .right:
            startFrame.origin.x = visibleFrame.maxX
        case .center:
            break
        }

        win.setFrame(startFrame, display: false)
        win.alphaValue = position == .center ? 0 : 1
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKey()

        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(targetFrame, display: true)
            if position == .center {
                win.animator().alphaValue = 1
            }
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
            self?.isVisible = true
        })
    }

    // MARK: - Hide

    private func hide() {
        guard let win = window else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let currentFrame = win.frame
        lastFrame = currentFrame

        var endFrame = currentFrame
        switch position {
        case .top:
            endFrame.origin.y = visibleFrame.maxY
        case .bottom:
            endFrame.origin.y = visibleFrame.minY - currentFrame.height
        case .left:
            endFrame.origin.x = visibleFrame.minX - currentFrame.width
        case .right:
            endFrame.origin.x = visibleFrame.maxX
        case .center:
            break
        }

        isAnimating = true
        // Use a slightly faster hide than show for snappier feel
        let hideDuration = animationDuration * 0.7
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(endFrame, display: true)
            win.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            win.alphaValue = 1 // reset for next show
            self?.isAnimating = false
            self?.isVisible = false

            // Give focus back to the previously active app. Check if cmux
            // has any other visible main windows; if not, deactivate entirely.
            DispatchQueue.main.async {
                let hasOtherVisibleWindow = NSApp.windows.contains { w in
                    w !== win && w.isVisible && !w.isMiniaturized
                        && w.windowNumber > 0
                        && (w.styleMask.contains(.titled) || w.styleMask.contains(.fullSizeContentView))
                }
                if !hasOtherVisibleWindow {
                    NSApp.hide(nil)
                }
            }
        })
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            if isVisible, !isAnimating {
                hide()
            }
        }
        return false
    }

    // MARK: - Window Creation

    private func createQuickTerminalWindow() -> NSWindow {
        let manager = TabManager()
        self.tabManager = manager

        let sidebarState = SidebarState(isVisible: true)
        self.sidebarState = sidebarState
        let sidebarSelectionState = SidebarSelectionState(selection: .tabs)
        self.sidebarSelectionState = sidebarSelectionState
        let notificationStore = TerminalNotificationStore.shared

        // Apply pending session snapshot BEFORE creating the ContentView so
        // SwiftUI initializes with the restored workspaces, not empty state.
        if let snapshot = pendingSessionSnapshot {
            pendingSessionSnapshot = nil
            manager.restoreSessionSnapshot(snapshot.tabManager)
            sidebarState.isVisible = snapshot.sidebar.isVisible
            sidebarState.persistedWidth = CGFloat(
                SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
            )
            sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection
        }

        let wId = UUID()
        self.windowId = wId

        let root = ContentView(
            updateViewModel: AppDelegate.shared?.updateViewModel ?? UpdateViewModel(),
            windowId: wId
        )
        .environmentObject(manager)
        .environmentObject(notificationStore)
        .environmentObject(sidebarState)
        .environmentObject(sidebarSelectionState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "quickTerminal.title", defaultValue: "Quick Terminal")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.quickTerminal")
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self

        // Safety net: if the window is somehow destroyed despite windowShouldClose,
        // reset state so toggle() will recreate it.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window = nil
            self.tabManager = nil
            self.sidebarState = nil
            self.sidebarSelectionState = nil
            self.isVisible = false
        }

        // Register with AppDelegate so terminal surfaces work properly
        if let appDelegate = AppDelegate.shared {
            appDelegate.registerMainWindow(
                window,
                windowId: wId,
                tabManager: manager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState
            )
            appDelegate.applyWindowDecorations(to: window)
        }

        return window
    }

    // MARK: - Frame Calculation

    private func quickTerminalFrame(in visibleFrame: NSRect) -> NSRect {
        switch position {
        case .top:
            let height = visibleFrame.height * screenFraction
            return NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - height,
                width: visibleFrame.width,
                height: height
            )
        case .bottom:
            let height = visibleFrame.height * screenFraction
            return NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: height
            )
        case .left:
            let width = visibleFrame.width * screenFraction
            return NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: width,
                height: visibleFrame.height
            )
        case .right:
            let width = visibleFrame.width * screenFraction
            return NSRect(
                x: visibleFrame.maxX - width,
                y: visibleFrame.minY,
                width: width,
                height: visibleFrame.height
            )
        case .center:
            let width = visibleFrame.width * 0.8
            let height = visibleFrame.height * 0.8
            return NSRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
        }
    }

    // MARK: - Session Restore

    /// Stash a session snapshot to be applied when the visor window is first created.
    private var pendingSessionSnapshot: SessionWindowSnapshot?

    /// Queue a session snapshot for deferred restore.
    /// The snapshot is applied lazily in `createQuickTerminalWindow()` so we
    /// don't create an AppKit window during startup restore (which would
    /// re-enter `registerMainWindow` / `attemptStartupSessionRestoreIfNeeded`).
    func restoreSession(_ snapshot: SessionWindowSnapshot) {
        pendingSessionSnapshot = snapshot
    }
}
