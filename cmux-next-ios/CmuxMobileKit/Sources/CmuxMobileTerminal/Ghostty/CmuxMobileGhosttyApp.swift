#if os(iOS)
import CmuxMobileDesign
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
    /// The config the app runs with; replaced (and the old one freed) on each theme change.
    private var config: ghostty_config_t
    /// The text `config` was loaded from: an identical one is not applied again.
    private var configText: String
    private var tickScheduled = false
    /// Whether the terminal draws its dark or light colors (the window's scheme).
    private var isDark = true

    private static var current: CmuxMobileGhosttyApp?
    nonisolated static let wakeupGate = WakeupGate()

    /// The terminal's background: the current appearance's terminal theme
    /// (true black in the neutral look), resolved per scheme and per theme.
    static var background: UIColor { CmuxMobileColorRole.terminalBackground.uiColor }

    static func shared() throws -> CmuxMobileGhosttyApp {
        if let current { return current }
        let made = try CmuxMobileGhosttyApp()
        current = made
        return made
    }

    /// Ghostty's runtime callbacks, nonisolated: Ghostty calls them from its
    /// renderer and IO threads.
    nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
        // One hop to the main queue: actions (the scrollbar) must reach the
        // screen before the frames that follow them (see TerminalViewController).
        // Wakeups arrive from Ghostty's threads, as often as output is
        // parsed; one tick is queued at a time.
        let wakeup: ghostty_runtime_wakeup_cb = { _ in
            guard CmuxMobileGhosttyApp.wakeupGate.claim() else { return }
            DispatchQueue.main.async {
                CmuxMobileGhosttyApp.wakeupGate.release()
                MainActor.assumeIsolated { CmuxMobileGhosttyApp.current?.tick() }
            }
        }
        let actionCallback: ghostty_runtime_action_cb = { _, target, action in
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
        let writeClipboard: ghostty_runtime_write_clipboard_cb = { _, _, content, count, _ in
            guard count > 0 else { return }
            let item = content.pointee
            let text = String(decoding: UnsafeRawBufferPointer(start: item.data, count: item.len), as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
        }
        return ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: wakeup,
            action_cb: actionCallback,
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: writeClipboard,
            close_surface_cb: { _, _ in }
        )
    }

    private init() throws {
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == GHOSTTY_SUCCESS else { throw Failure.initFailed(status) }
        let text = Self.productConfig(theme: CmuxMobileAppearance.shared.terminal, dark: true)
        guard let config = Self.makeConfig(text) else { throw Failure.appCreationFailed }
        // Built outside the main actor: Ghostty calls these from its own
        // threads, and a closure formed in this @MainActor init would carry
        // main-actor isolation (Swift traps when the renderer thread calls it).
        var runtime = Self.runtimeConfig()
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw Failure.appCreationFailed
        }
        self.app = app
        self.config = config
        configText = text
        CmuxMobileAppearance.shared.observe("terminal") { _ in CmuxMobileGhosttyApp.current?.applyTheme() }
    }

    /// The window's scheme changed (a surface saw it): the terminal takes that scheme's colors.
    func setDark(_ dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        applyTheme()
    }

    /// Gives every surface the current theme (`ghostty_app_update_config`
    /// updates each live surface): colors, palette, cursor, selection and the
    /// font family. The font size stays the phone's setting.
    func applyTheme() {
        let text = Self.productConfig(theme: CmuxMobileAppearance.shared.terminal, dark: isDark)
        guard text != configText, let next = Self.makeConfig(text) else { return }
        ghostty_app_update_config(app, next)
        ghostty_config_free(config)
        config = next
        configText = text
    }

    private static func makeConfig(_ text: String) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-mobile-ghostty.conf")
        if (try? Data(text.utf8).write(to: url, options: .atomic)) != nil {
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)
        return config
    }

    /// Product settings: no padding (rows land on exact multiples of the cell
    /// height, which native scrolling relies on), the scrollback cap, no
    /// auto-scroll (the screen owns the viewport), and the theme: the Mac's
    /// terminal colors and font family when the phone matches a Mac
    /// (`theme`), else the app's black. A family the phone does not have is
    /// left out, so the terminal keeps its own font.
    static func productConfig(theme: CmuxMobileTerminalTheme, dark: Bool) -> String {
        let colors = theme.colors(dark: dark)
        var lines = [
            "scrollback-limit-bytes = \(8 * 1024 * 1024)",
            "window-padding-x = 0",
            "window-padding-y = 0",
            "window-padding-balance = false",
            "background = \(colors.background.hex)",
            "foreground = \(colors.foreground.hex)",
            "cursor-style = block",
            "cursor-style-blink = false",
            "scroll-to-bottom = no-keystroke,no-output",
        ]
        for (index, color) in colors.palette.prefix(16).enumerated() { lines.append("palette = \(index)=\(color.hex)") }
        if let cursor = colors.cursor { lines.append("cursor-color = \(cursor.hex)") }
        if let selection = colors.selectionBackground { lines.append("selection-background = \(selection.hex)") }
        if let selection = colors.selectionForeground { lines.append("selection-foreground = \(selection.hex)") }
        if let family = theme.fontFamily, isInstalled(family: family) { lines.append("font-family = \(family)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether iOS has a font family of that name (the Mac's family may not be on the phone).
    static func isInstalled(family: String) -> Bool {
        let wanted = family.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, !wanted.contains("\n"), !wanted.contains("\"") else { return false }
        return UIFont.familyNames.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            || UIFont(name: wanted, size: 12) != nil
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
