import AppKit
import GhosttyKit

/// Carries a C pointer across an actor hop. Only sound where Ghostty
/// documents the pointer as valid until the matching completion call.
nonisolated struct UncheckedPointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer?
}

// MARK: - C callbacks
//
// libghostty calls wakeup_cb from any thread. Action and clipboard callbacks
// arrive on the main thread during ghostty_app_tick or a surface call; the
// handlers still check and hop so an off-main caller can never touch AppKit.

nonisolated func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let context = RuntimeCallbackContext.from(userdata) else { return }
    guard context.pending.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
        return
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { context.runtime?.tick() }
    }
}

nonisolated func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    // Decode synchronously: strings in the action are valid only for the
    // duration of this callback.
    guard let decoded = GhosttyActionDecoder.decode(action) else { return false }
    let bridge: SurfaceBridge? = if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
        SurfaceBridge.from(ghostty_surface_userdata(surface))
    } else {
        nil
    }
    let context = app.flatMap { RuntimeCallbackContext.from(ghostty_app_userdata($0)) }
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            GhosttyActionDispatcher.dispatch(decoded, bridge: bridge, runtime: context?.runtime)
        }
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            _ = GhosttyActionDispatcher.dispatch(decoded, bridge: bridge, runtime: context?.runtime)
        }
    }
    return true
}

/// Paste and OSC 52 reads. Completes synchronously when the pasteboard has
/// text-like content; returning false lets a performable paste binding fall
/// through to the terminal.
nonisolated func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    guard Thread.isMainThread, let bridge = SurfaceBridge.from(userdata) else { return false }
    let location: TerminalPasteboardLocation = clipboard == GHOSTTY_CLIPBOARD_SELECTION ? .selection : .standard
    let pointer = UncheckedPointer(raw: state)
    return MainActor.assumeIsolated {
        guard let view = bridge.view else { return false }
        return view.clipboardRequests.completeRead(location: location, state: pointer)
    }
}

nonisolated func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ text: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let bridge = SurfaceBridge.from(userdata) else { return }
    let contents = text.map { String(cString: $0) } ?? ""
    let kind: TerminalClipboardRequestKind = switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ: .osc52Read
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE: .osc52Write
    default: .paste
    }
    let pointer = UncheckedPointer(raw: state)
    let run: @MainActor @Sendable () -> Void = {
        bridge.view?.clipboardRequests.confirm(contents: contents, kind: kind, state: pointer)
    }
    if Thread.isMainThread {
        MainActor.assumeIsolated(run)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(run) }
    }
}

nonisolated func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard let contents, count > 0 else { return }
    var items: [TerminalClipboardItem] = []
    for index in 0..<count {
        let item = contents[index]
        guard let data = item.data else { continue }
        let mime = item.mime.map { String(cString: $0) } ?? "text/plain"
        items.append(TerminalClipboardItem(mime: mime, text: String(cString: data)))
    }
    guard !items.isEmpty else { return }
    let location: TerminalPasteboardLocation = clipboard == GHOSTTY_CLIPBOARD_SELECTION ? .selection : .standard
    let bridge = SurfaceBridge.from(userdata)
    let run: @MainActor @Sendable () -> Void = {
        if confirm, let view = bridge?.view {
            view.clipboardRequests.confirmWrite(items: items, location: location)
        } else {
            TerminalPasteboard.write(items, to: location)
        }
    }
    if Thread.isMainThread {
        MainActor.assumeIsolated(run)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(run) }
    }
}

nonisolated func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let bridge = SurfaceBridge.from(userdata) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { bridge.view?.surfaceRequestedClose() }
    }
}

/// tmux control mode is a local-PTY Ghostty feature; cmux-tui owns
/// multiplexing, so these events are ignored.
nonisolated func ghosttyTmuxControl(
    _ userdata: UnsafeMutableRawPointer?,
    _ event: ghostty_tmux_event_e,
    _ id: UInt32,
    _ bytes: UnsafePointer<UInt8>?,
    _ length: UInt
) {}
