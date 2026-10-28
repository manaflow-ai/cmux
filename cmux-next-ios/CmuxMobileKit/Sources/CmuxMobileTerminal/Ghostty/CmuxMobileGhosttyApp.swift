#if os(iOS)
import Foundation
import GhosttyNextKit
import UIKit

/// The process-wide libghostty app for cmux-next-ios (adapted from CmuxiOSTerminal's
/// GhosttyNextApp). It owns the config and the app mailbox; surfaces register
/// to receive the actions they need (scrollbar, title). Wakeups from Ghostty's
/// threads drain the mailbox on the main actor.
@MainActor
final class CmuxMobileGhosttyApp {
    enum Failure: Error { case initFailed(Int32), appCreationFailed }

    let app: ghostty_app_t
    private let config: ghostty_config_t
    private var tickScheduled = false

    private static var current: CmuxMobileGhosttyApp?
    nonisolated static let wakeupGate = WakeupGate()

    /// Terminal theme: true black like the app chrome, the cmux-next ANSI palette.
    static let background = UIColor(red: 0, green: 0, blue: 0, alpha: 1)

    static func shared() throws -> CmuxMobileGhosttyApp {
        if let current { return current }
        let made = try CmuxMobileGhosttyApp()
        current = made
        return made
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        guard let config = ghostty_config_new() else { throw Failure.appCreationFailed }
        Self.loadProductConfig(config)
        ghostty_config_finalize(config)
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        // One hop to the main queue: actions (the scrollbar) must reach the
        // screen before the frames that follow them (see TerminalViewController).
        // Wakeups arrive from Ghostty's threads, as often as output is
        // parsed; one tick is queued at a time.
        runtime.wakeup_cb = { _ in
            guard CmuxMobileGhosttyApp.wakeupGate.claim() else { return }
            DispatchQueue.main.async {
                CmuxMobileGhosttyApp.wakeupGate.release()
                MainActor.assumeIsolated { CmuxMobileGhosttyApp.current?.tick() }
            }
        }
        runtime.action_cb = { _, target, action in
            guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface else { return false }
            let event: TerminalSurfaceEvent?
            switch action.tag {
            case GHOSTTY_ACTION_SCROLLBAR:
                let bar = action.action.scrollbar
                event = .scrollbar(total: Int(bar.total), offset: Int(bar.offset), visible: Int(bar.len))
            case GHOSTTY_ACTION_CELL_SIZE:
                event = .cellSize
            case GHOSTTY_ACTION_RING_BELL:
                event = .bell
            default:
                event = nil
            }
            guard let event, let userdata = ghostty_surface_userdata(surface) else { return false }
            // Userdata is the surface's InputBox (not the view): it stays alive
            // until the surface is freed, and it is retained here for the hop,
            // so a closed tab's event finds a nil view instead of freed memory.
            let box = SendableBox(Unmanaged<InputBox>.fromOpaque(userdata).takeUnretainedValue())
            let deliver = { @MainActor in box.value.view?.receive(event) }
            if Thread.isMainThread {
                MainActor.assumeIsolated { deliver() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver() } }
            }
            return true
        }
        runtime.read_clipboard_cb = { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, content, count, _ in
            guard let content, count > 0, let data = content.pointee.data else { return }
            let text = String(decoding: UnsafeRawBufferPointer(start: data, count: content.pointee.len), as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }
        runtime.close_surface_cb = { _, _ in }
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw Failure.appCreationFailed
        }
        self.app = app
        self.config = config
    }

    /// Product settings: no padding (rows land on exact multiples of the cell
    /// height, which native scrolling relies on), the app's black, the
    /// scrollback cap, and no auto-scroll: the screen owns the viewport.
    private static func loadProductConfig(_ config: ghostty_config_t) {
        let text = """
        scrollback-limit-bytes = \(8 * 1024 * 1024)
        window-padding-x = 0
        window-padding-y = 0
        window-padding-balance = false
        background = #000000
        foreground = #E6E6E6
        cursor-style = block
        cursor-style-blink = false
        scroll-to-bottom = no-keystroke,no-output
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-mobile-ghostty.conf")
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        url.path.withCString { ghostty_config_load_file(config, $0) }
    }

    private func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        Task { @MainActor in
            self.tickScheduled = false
            self.tick()
        }
    }

    func tick() {
        ghostty_app_tick(app)
    }
}

/// Surface actions the screen reacts to.
enum TerminalSurfaceEvent: Sendable {
    case scrollbar(total: Int, offset: Int, visible: Int)
    case cellSize
    case bell
}
/// At most one queued main-thread tick for Ghostty's wakeups.
final class WakeupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queued = false

    /// True when the caller should queue a tick (none is queued).
    func claim() -> Bool {
        lock.withLock {
            defer { queued = true }
            return !queued
        }
    }

    /// The queued tick is running; a later wakeup queues another.
    func release() {
        lock.withLock { queued = false }
    }
}

/// Carries a main-actor object across the main-queue hop above.
private struct SendableBox<Value: AnyObject>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
