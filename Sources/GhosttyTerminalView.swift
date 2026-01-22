import SwiftUI
import AppKit
import Metal
import QuartzCore

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private var appObservers: [NSObjectProtocol] = []

    private init() {
        initializeGhostty()
    }

    private func initializeGhostty() {
        // Initialize Ghostty library first
        let result = ghostty_init(0, nil)
        if result != GHOSTTY_SUCCESS {
            print("Failed to initialize ghostty: \(result)")
            return
        }

        // Load config
        config = ghostty_config_new()
        guard let config = config else {
            print("Failed to create ghostty config")
            return
        }

        // Load default config
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                // Wakeup - trigger redraw if needed
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Read clipboard
        }
        runtimeConfig.write_clipboard_cb = { userdata, location, content, len, confirm in
            // Write clipboard
            if let content = content {
                let data = Data(bytes: content, count: Int(len))
                if let string = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(string, forType: .string)
                    }
                }
            }
        }
        runtimeConfig.close_surface_cb = { userdata, processAlive in
            // Surface closed
        }

        // Create app
        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            print("Failed to create ghostty app")
            return
        }

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
        #endif
    }

    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return false }
        let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()

        switch action.tag {
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.scrollbar = scrollbar
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
            )
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            surfaceView.cellSize = cellSize
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateCellSize,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.cellSize: cellSize]
            )
            return true
        default:
            return false
        }
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

class TerminalSurface {
    private(set) var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?
    private weak var attachedView: GhosttyNSView?

    init() {
        // Surface is created when attached to a view
    }

    func attachToView(_ view: GhosttyNSView) {
        // If already attached to this view, nothing to do
        if attachedView === view && surface != nil {
            updateMetalLayer(for: view)
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it
        if surface == nil {
            createSurface(for: view)
        } else {
            // Re-attach existing surface to new view
            reattachSurface(to: view)
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            return
        }

        let scale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        updateMetalLayer(for: view)

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = scale
        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_TAB

        surface = ghostty_surface_new(app, &surfaceConfig)

        if surface == nil {
            print("Failed to create ghostty surface")
            return
        }

        ghostty_surface_set_size(
            surface,
            UInt32(view.bounds.width * scale),
            UInt32(view.bounds.height * scale)
        )

        setupDisplayLink()
    }

    private func reattachSurface(to view: GhosttyNSView) {
        guard let surface = surface else { return }

        let scale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        updateMetalLayer(for: view)
        // Update the nsview pointer in the surface
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(
            surface,
            UInt32(view.bounds.width * scale),
            UInt32(view.bounds.height * scale)
        )
    }

    private func updateMetalLayer(for view: GhosttyNSView) {
        let scale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            if view.bounds.width > 0 && view.bounds.height > 0 {
                metalLayer.drawableSize = CGSize(
                    width: view.bounds.width * scale,
                    height: view.bounds.height * scale
                )
            }
        }
    }

    private func setupDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let newLink = link else { return }

        displayLink = newLink

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, _ -> CVReturn in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(newLink, callback, nil)
        CVDisplayLinkStart(newLink)
    }

    func updateSize(width: CGFloat, height: CGFloat, scale: CGFloat) {
        guard let surface = surface else { return }
        ghostty_surface_set_size(surface, UInt32(width * scale), UInt32(height * scale))

        if let view = attachedView, let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(width: width * scale, height: height * scale)
        }
    }

    func setFocus(_ focused: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView {
    var terminalSurface: TerminalSurface?
    private var surfaceAttached = false
    var scrollbar: GhosttyScrollbar?
    var cellSize: CGSize = .zero
    var desiredFocus: Bool = false
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        installEventMonitor()
        updateTrackingAreas()
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }

        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        terminalSurface = surface
        surfaceAttached = false
        attachSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !surfaceAttached else { return }
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard window != nil else { return }

        surfaceAttached = true
        terminalSurface.attachToView(self)
        terminalSurface.setFocus(desiredFocus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            attachSurfaceIfNeeded()
            updateSurfaceSize()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachSurfaceIfNeeded()
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        attachSurfaceIfNeeded()
    }

    private func updateSurfaceSize() {
        guard let terminalSurface = terminalSurface else { return }
        let scale = window?.screen?.backingScaleFactor ?? 2.0
        terminalSurface.updateSize(width: bounds.width, height: bounds.height, scale: scale)
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }

    // For NSTextInputClient - accumulates text during key events
    private var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let the input system handle the event (for IME, dead keys, etc.)
        interpretKeyEvents([event])

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromEvent(event)
        keyEvent.composing = markedText.length > 0
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Use accumulated text from insertText (for IME), or compute text for key
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            if let text = textForKeyEvent(event) {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        // First try charactersIgnoringModifiers to get the base character
        // This is important for control keys - we want 'c' not '\x03' (ETX)
        if event.modifierFlags.contains(.control) {
            // For control+key, return the unmodified character
            // Ghostty's KeyEncoder will handle the ctrl encoding internally
            return event.charactersIgnoringModifiers
        }

        guard let chars = event.characters, !chars.isEmpty else {
            return nil
        }

        // Check if the first character is a control character or PUA
        if let scalar = chars.unicodeScalars.first {
            // Control characters (< 0x20) should not be sent as text
            // Ghostty handles these internally via keycode + mods
            if scalar.value < 0x20 {
                return nil
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return 0
        }
        return scalar.value
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        terminalSurface?.setFocus(true)
        var mods: Int32 = 0
        if event.modifierFlags.contains(.shift) { mods |= Int32(GHOSTTY_MODS_SHIFT.rawValue) }
        if event.modifierFlags.contains(.control) { mods |= Int32(GHOSTTY_MODS_CTRL.rawValue) }
        if event.modifierFlags.contains(.option) { mods |= Int32(GHOSTTY_MODS_ALT.rawValue) }
        if event.modifierFlags.contains(.command) { mods |= Int32(GHOSTTY_MODS_SUPER.rawValue) }

        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    override func scrollWheel(with event: NSEvent) {
        if let surfaceView {
            if window?.firstResponder !== surfaceView {
                window?.makeFirstResponder(surfaceView)
            }
            surfaceView.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

final class GhosttySurfaceScrollView: NSView {
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var isActive = true
    private var focusWorkItem: DispatchWorkItem?

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        scrollView = GhosttyScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(surfaceView)
        return true
    }

    override func resignFirstResponder() -> Bool {
        _ = surfaceView.resignFirstResponder()
        return true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
            self?.requestFocus()
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
        })
        updateFocusForWindow()
        if window.isKeyWindow { requestFocus() }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateFocusForWindow()
        if active {
            requestFocus()
        } else {
            cancelFocusRequest()
        }
    }

    private func updateFocusForWindow() {
        let shouldFocus = isActive && (window?.isKeyWindow ?? false)
        surfaceView.desiredFocus = shouldFocus
        surfaceView.terminalSurface?.setFocus(shouldFocus)
    }

    private func requestFocus(delay: TimeInterval? = nil) {
        guard isActive else { return }
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        cancelFocusRequest()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            guard let window = self.window else {
                self.requestFocus(delay: nextDelay)
                return
            }
            guard window.isKeyWindow else { return }

            if window.firstResponder === self.surfaceView {
                return
            }

            if let responder = window.firstResponder as? NSView, responder !== self.surfaceView {
                _ = responder.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)

            if window.firstResponder !== self.surfaceView {
                self.requestFocus(delay: nextDelay)
            }
        }

        let queue = DispatchQueue.main
        focusWorkItem = work
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    private func cancelFocusRequest() {
        focusWorkItem?.cancel()
        focusWorkItem = nil
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
        guard isLiveScrolling else { return }
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Otherwise send directly to the terminal
        if let surface = surface {
            chars.withCString { ptr in
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 0
                keyEvent.mods = GHOSTTY_MODS_NONE
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = ptr
                keyEvent.composing = false
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    let terminalSurface: TerminalSurface
    var isActive: Bool = true

    func makeNSView(context: Context) -> GhosttySurfaceScrollView {
        let surfaceView = GhosttyNSView(frame: .zero)
        let view = GhosttySurfaceScrollView(surfaceView: surfaceView)
        view.attachSurface(terminalSurface)
        view.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceScrollView, context: Context) {
        nsView.attachSurface(terminalSurface)
        nsView.setActive(isActive)
    }
}
