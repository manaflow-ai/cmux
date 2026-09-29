public import GhosttyKit
import AppKit
import Synchronization

/// Process-wide libghostty app. All `ghostty_*` calls stay inside this module
/// so a GhosttyKit bump touches one target (plans/cmux-next/shell.md 2.3).
///
/// Created lazily on first access; accessing `shared` calls `ghostty_init`.
public final class GhosttyRuntime {
    public static let shared = GhosttyRuntime()

    /// Nil when libghostty failed to initialize; surfaces then stay blank.
    public private(set) var app: ghostty_app_t?

    private let config: ghostty_config_t?
    private let wakeup = WakeupCoalescer()

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            config = nil
            return
        }
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(wakeup).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = ghosttyWakeup
        runtime.action_cb = ghosttyAction
        runtime.read_clipboard_cb = ghosttyReadClipboard
        runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        runtime.write_clipboard_cb = ghosttyWriteClipboard
        runtime.close_surface_cb = ghosttyCloseSurface
        runtime.tmux_control_cb = ghosttyTmuxControl
        app = ghostty_app_new(&runtime, config)
    }

    /// Runs one libghostty app tick. Called on the main actor after a
    /// coalesced wakeup.
    func tick() {
        wakeup.pending.store(false, ordering: .releasing)
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Forward app activation so Ghostty can dim unfocused cursors.
    public func setAppFocused(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}

/// Collapses bursts of `wakeup_cb` (any thread) into one main-actor tick.
nonisolated final class WakeupCoalescer: Sendable {
    let pending = Atomic<Bool>(false)
}

// MARK: - C callbacks
//
// libghostty invokes these on arbitrary threads. Each copies what it needs
// into Sendable values and hops to the main actor; none touches AppKit or
// main-actor state directly.

nonisolated private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let coalescer = Unmanaged<WakeupCoalescer>.fromOpaque(userdata).takeUnretainedValue()
    guard coalescer.pending.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
        return
    }
    Task { @MainActor in
        GhosttyRuntime.shared.tick()
    }
}

/// Frontend-owned actions (title, pwd, bell, notifications, mouse shape)
/// are not handled yet; returning false lets Ghostty apply its defaults.
nonisolated private func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    false
}

/// Clipboard reads (paste via OSC 52 and bindings) are not supported yet.
nonisolated private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    false
}

nonisolated private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ text: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {}

nonisolated private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard clipboard == GHOSTTY_CLIPBOARD_STANDARD, let contents, count > 0 else { return }
    var text: String?
    for index in 0..<count {
        let item = contents[index]
        guard let data = item.data else { continue }
        let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
        if mime.hasPrefix("text/plain") {
            text = String(cString: data)
            break
        }
    }
    guard let text else { return }
    Task { @MainActor in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

nonisolated private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}

nonisolated private func ghosttyTmuxControl(
    _ userdata: UnsafeMutableRawPointer?,
    _ event: ghostty_tmux_event_e,
    _ id: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: UInt
) {}
