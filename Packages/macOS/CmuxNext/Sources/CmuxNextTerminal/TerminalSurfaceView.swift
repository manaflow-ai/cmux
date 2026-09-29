public import AppKit
public import Foundation
import GhosttyKit

/// NSView that hosts one Ghostty surface.
///
/// Ghostty's Metal renderer installs its own `IOSurfaceLayer` as this view's
/// layer; never replace the layer. The surface is created when the view first
/// joins a window and freed when the view deinitializes.
///
/// Not yet implemented (next CmuxNextTerminal steps, shell.md section 5):
/// `NSTextInputClient` / IME, render-presented callbacks, occlusion, Kitty
/// replay restore, and authoritative grid size from the daemon.
public final class TerminalSurfaceView: NSView {
    public enum IOMode {
        /// Ghostty spawns and owns the shell. Used to validate input and
        /// rendering before the daemon client exists.
        case exec
        /// cmux-tui owns the PTY and answers terminal queries. User input
        /// bytes go to `write` on Ghostty's IO thread; daemon output comes
        /// back through `processOutput(_:)`.
        case manualMirror(write: @Sendable (Data) -> Void)
    }

    private let ioMode: IOMode
    private var surface: ghostty_surface_t?
    private var ioWriteBox: Unmanaged<IOWriteBox>?
    private var trackingArea: NSTrackingArea?

    public init(ioMode: IOMode) {
        self.ioMode = ioMode
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
        // The IO box must outlive ghostty_surface_free, which joins the IO thread.
        ioWriteBox?.release()
    }

    // MARK: Manual IO

    /// Feeds PTY bytes from the daemon. Calls must be serialized per surface.
    public func processOutput(_ data: Data) {
        guard let surface, !data.isEmpty else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, base, UInt(buffer.count))
        }
    }

    // MARK: Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, surface == nil else { return }
        createSurface(scale: window.backingScaleFactor)
    }

    private func createSurface(scale: CGFloat) {
        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        let viewPointer = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: viewPointer))
        config.userdata = viewPointer
        config.scale_factor = scale
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        switch ioMode {
        case .exec:
            config.io_mode = GHOSTTY_SURFACE_IO_EXEC
        case .manualMirror(let write):
            let box = Unmanaged.passRetained(IOWriteBox(write: write))
            ioWriteBox = box
            config.io_mode = GHOSTTY_SURFACE_IO_MANUAL_MIRROR
            config.io_write_cb = ghosttyIOWrite
            config.io_write_userdata = box.toOpaque()
        }
        surface = ghostty_surface_new(app, &config)
        updateContentScale()
        updateSurfaceSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
        updateSurfaceSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateContentScale() {
        guard let surface, let window else { return }
        let scale = convertToBacking(NSSize(width: 1, height: 1))
        ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        if let screenNumber = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
        }
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds.size)
        guard pixels.width > 0, pixels.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
    }

    // MARK: Focus

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface { ghostty_surface_set_focus(surface, true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, let surface { ghostty_surface_set_focus(surface, false) }
        return accepted
    }

    // MARK: Keyboard (no IME yet)

    public override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    public override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        key.keycode = UInt32(event.keyCode)
        key.composing = false
        key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
        // Control characters are encoded by Ghostty from keycode + mods.
        let text = event.characters.flatMap { chars in
            chars.unicodeScalars.first.map { $0.value >= 0x20 ? chars : nil } ?? nil
        }
        if action != GHOSTTY_ACTION_RELEASE, let text {
            text.withCString { pointer in
                key.text = pointer
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    public override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    public override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    public override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    public override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    public override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        // Bit 0 of the scroll mods marks precise (trackpad) deltas.
        let scrollMods: ghostty_input_scroll_mods_t = event.hasPreciseScrollingDeltas ? 1 : 0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    private func sendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Ghostty expects a top-left origin in points.
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }
}

/// Retained across the surface lifetime and handed to Ghostty as
/// `io_write_userdata`.
nonisolated final class IOWriteBox: Sendable {
    let write: @Sendable (Data) -> Void

    init(write: @escaping @Sendable (Data) -> Void) {
        self.write = write
    }
}

/// Runs on Ghostty's IO thread: copy the bytes and hand them off.
nonisolated private func ghosttyIOWrite(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<CChar>?, _ length: UInt) {
    guard let userdata, let bytes, length > 0 else { return }
    let box = Unmanaged<IOWriteBox>.fromOpaque(userdata).takeUnretainedValue()
    box.write(Data(bytes: bytes, count: Int(length)))
}
