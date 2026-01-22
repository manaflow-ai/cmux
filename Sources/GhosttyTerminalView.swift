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
            // Handle actions
            return false
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
        }
    }

    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
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
        if let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
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
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = markedText.length > 0

        // Use accumulated text from insertText, or fall back to event characters
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // No accumulated text - send the key with event characters
            if let chars = event.characters, !chars.isEmpty {
                // Filter out control characters
                var hasControlChars = false
                for scalar in chars.unicodeScalars where scalar.value < 0x20 {
                    hasControlChars = true
                    break
                }
                if hasControlChars {
                    keyEvent.text = nil
                } else {
                    chars.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                        return
                    }
                    return
                }
            } else {
                keyEvent.text = nil
            }
            _ = ghostty_surface_key(surface, keyEvent)
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

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
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
        terminalSurface = nil
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

    func makeNSView(context: Context) -> GhosttyNSView {
        let view = GhosttyNSView(frame: .zero)
        view.attachSurface(terminalSurface)
        // Focus after view is in window
        if isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        // Ensure the surface is attached
        nsView.attachSurface(terminalSurface)

        if isActive {
            // Focus on tab switch and notify surface
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else {
            // Unfocus when tab becomes inactive
            terminalSurface.setFocus(false)
        }
    }
}
