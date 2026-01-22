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

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView {
    private var surface: ghostty_surface_t?
    private var displayLink: CVDisplayLink?
    private var metalDevice: MTLDevice?
    private var surfaceCreated = false

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.metalDevice = metalLayer.device
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

    private func createSurfaceIfNeeded() {
        // Only create once and when we have a valid size
        guard !surfaceCreated else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard window != nil else { return }

        surfaceCreated = true
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            return
        }

        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        // Update Metal layer with initial size
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS

        // Pass this view to ghostty
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()

        // Set scale factor
        surfaceConfig.scale_factor = scale

        surfaceConfig.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // Create the surface
        surface = ghostty_surface_new(app, &surfaceConfig)

        if surface == nil {
            print("Failed to create ghostty surface")
            return
        }

        // Set initial size immediately after creation
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width * scale),
            UInt32(bounds.height * scale)
        )

        // Setup display link for rendering
        setupDisplayLink()
    }

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        self.displayLink = displayLink

        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext -> CVReturn in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback, nil)
        CVDisplayLinkStart(displayLink)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            createSurfaceIfNeeded()
            updateSurfaceSize()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        createSurfaceIfNeeded()
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        createSurfaceIfNeeded()
    }

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let scale = window?.screen?.backingScaleFactor ?? 2.0

        // Update Metal layer
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width * scale),
            UInt32(bounds.height * scale)
        )
    }

    // MARK: - Input Handling

    override var acceptsFirstResponder: Bool { true }

    private func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        for scalar in chars.unicodeScalars where scalar.value < 0x20 {
            return nil
        }
        return chars
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        interpretKeyEvents([event])

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false

        if let text = ghosttyCharacters(from: event) {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
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
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttyNSView {
        let view = GhosttyNSView(frame: .zero)
        // Focus after view is in window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        // Focus on tab switch
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
