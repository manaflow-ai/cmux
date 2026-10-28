import AppKit
import CmuxNextCompat
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface

/// Carries a Ghostty C handle across threads: the module's one reviewed
/// pointer hand-off. Swift never reads through it; Ghostty's contract keeps
/// each kind valid: a clipboard request state until its completion call, a
/// cloned config until it is freed, and a surface until `ghostty_surface_free`,
/// which ``TerminalOutputLane/close()`` fences.
// crash-allow: an immutable C address passed back to libghostty, never dereferenced in Swift; the handle's lifetime is Ghostty's documented contract above
@safe nonisolated struct UncheckedPointer: @unchecked Sendable {
    let raw: UnsafeMutableRawPointer?
}

// MARK: - C callbacks
//
// libghostty calls wakeup_cb from any thread; the tick it queues (one however many wakeups came)
// runs as the board task `ghostty.tick` (GhosttyTickClass). While output streams the ticks wait for
// the display frame, one per frame, and wakeups make no hop (GhosttyTickPacer). Every app mailbox
// message runs in a tick, so an OSC 52 read or write, a child exit or a close then waits at most
// until that frame; a paste confirm comes from the paste's own surface call. Action and clipboard callbacks
// arrive on the main thread during ghostty_app_tick or a surface call; the
// handlers still check, and an off-main caller reaches the main run loop's next
// pass (MainRunLoopBlock: one FIFO, so such calls keep their order) instead of
// touching AppKit. A surface's state actions wait in its GhosttyActionMailbox for
// its window's frame; its discrete actions, clipboard confirms and writes, and
// close flush that mailbox first, so each runs after the state Ghostty sent
// before it.

// Every `userdata` below is what cmux registered for its callback: the runtime's
// RuntimeCallbackContext's registry token, or a surface's SurfaceBridge, which outlives its surface
// (TerminalSurfaceView.deinit releases it after ghostty_surface_free returns).

nonisolated func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    // SAFETY: the runtime's userdata (above).
    guard let context = unsafe RuntimeCallbackContext.from(userdata), context.wake() else { return }
    // The wait starts here, on the waking thread: the board's ledger counts the run loop's queue too.
    context.hopToMain(posted: MainTaskPost(enqueueNanos: MainTaskPost.uptimeNanos()))
}

nonisolated func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    // Decode synchronously: strings in the action are valid only for the
    // duration of this callback.
    guard let decoded = GhosttyActionDecoder.decode(action) else { return false }
    // SAFETY: Ghostty targets a live surface of this app during the callback; its userdata is
    // the surface's SurfaceBridge (above).
    let bridge: SurfaceBridge? = if target.tag == GHOSTTY_TARGET_SURFACE, let surface = unsafe target.target.surface {
        // SAFETY: as above.
        unsafe SurfaceBridge.from(ghostty_surface_userdata(surface))
    } else {
        nil
    }
    // SAFETY: the live app's userdata is the runtime's context (above).
    let context = unsafe app.flatMap { unsafe RuntimeCallbackContext.from(ghostty_app_userdata($0)) }
    guard Thread.isMainThread else {
        MainRunLoopBlock.perform { _ = deliverGhosttyAction(decoded, bridge: bridge, runtime: context?.runtime) }
        return true
    }
    // main-proof: guarded by Thread.isMainThread above
    return MainActor.assumeIsolated { deliverGhosttyAction(decoded, bridge: bridge, runtime: context?.runtime) }
}

/// A surface's action goes through its bridge (``SurfaceBridge/deliver(_:runtime:)``); an app's runs now.
@MainActor private func deliverGhosttyAction(_ action: GhosttyAction, bridge: SurfaceBridge?, runtime: GhosttyRuntime?) -> Bool {
    guard let bridge else { return GhosttyActionDispatcher.dispatch(action, bridge: nil, runtime: runtime) }
    return bridge.deliver(action, runtime: runtime)
}

/// Paste and OSC 52 reads. Completes synchronously when the pasteboard has
/// text-like content; returning false lets a performable paste binding fall
/// through to the terminal.
nonisolated func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ mimeCount: Int,
    _ listAvailable: Bool
) -> ghostty_clipboard_read_result_e {
    // SAFETY: a surface's userdata (above).
    guard Thread.isMainThread, let bridge = unsafe SurfaceBridge.from(userdata) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let location: TerminalPasteboardLocation = clipboard == GHOSTTY_CLIPBOARD_SELECTION ? .selection : .standard
    // Text-like types always arrive as the canonical "text/plain"; the
    // terminal serves text only.
    var wantsText = false
    // SAFETY: Ghostty passes mimeCount NUL-terminated MIME strings, valid for this callback;
    // String(cString:) copies each.
    if let mimes = unsafe mimes {
        // SAFETY: as above.
        for index in 0..<mimeCount where unsafe mimes[index].map({ unsafe String(cString: $0) }) == "text/plain" {
            wantsText = true
        }
    }
    // SAFETY: the request's state, valid until its one completion or denial
    // (TerminalClipboardRequests).
    let pointer = unsafe UncheckedPointer(raw: state)
    // main-proof: guarded by Thread.isMainThread at the top of this function
    return MainActor.assumeIsolated {
        guard let view = bridge.view else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        return view.clipboardRequests.completeRead(location: location, wantsText: wantsText,
                                                   listAvailable: listAvailable, state: pointer)
    }
}

/// Unsafe paste or an OSC 52 / Kitty clipboard read that needs the user's
/// consent. The confirmation's contents are borrowed for this call only, so
/// the text is copied before the sheet opens.
nonisolated func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    // SAFETY: a surface's userdata (above).
    guard let bridge = unsafe SurfaceBridge.from(userdata) else { return }
    var contents = ""
    var contentBytes = 0
    var chosePlainText = false
    // SAFETY: Ghostty passes one confirmation with contents_len items, each MIME a NUL-terminated
    // string, all valid for this callback and copied before it returns.
    if let confirm = unsafe confirm?.pointee, let items = unsafe confirm.contents {
        for index in 0..<confirm.contents_len {
            // SAFETY: as above.
            let item = unsafe items[index]
            // SAFETY: as above.
            let mime = unsafe item.mime.map({ unsafe String(cString: $0) }) ?? "text/plain"
            let text = TerminalClipboardRequests.string(item)
            let (itemBytes, itemOverflow) = mime.utf8.count.addingReportingOverflow(item.len)
            let (next, totalOverflow) = contentBytes.addingReportingOverflow(itemBytes)
            contentBytes = itemOverflow || totalOverflow ? TerminalClipboardRequests.maxProgramWriteBytes + 1 : next
            if contents.isEmpty, !chosePlainText { contents = text }
            if !chosePlainText, mime.hasPrefix("text/plain") {
                contents = text
                chosePlainText = true
            }
        }
    }
    let kind: TerminalClipboardRequestKind = switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ, GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ: .osc52Read
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: .osc52Write
    default: .paste
    }
    // SAFETY: the request's state, valid until its one completion or denial
    // (TerminalClipboardRequests).
    let pointer = unsafe UncheckedPointer(raw: state)
    let run: @MainActor @Sendable () -> Void = {
        bridge.confirmClipboard(contents: contents, contentBytes: contentBytes, kind: kind, state: pointer)
    }
    if Thread.isMainThread {
        // main-proof: guarded by Thread.isMainThread above
        MainActor.assumeIsolated(run)
    } else {
        MainRunLoopBlock.perform(run)
    }
}

nonisolated func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    // SAFETY: Ghostty passes `count` contents, each MIME a NUL-terminated string, all valid for
    // this callback and copied before it returns.
    guard let contents = unsafe contents, count > 0 else { return }
    var items: [TerminalClipboardItem] = []
    for index in 0..<count {
        // SAFETY: as above.
        let item = unsafe contents[index]
        // SAFETY: as above.
        guard unsafe item.data != nil else { continue }
        // SAFETY: as above.
        let mime = unsafe item.mime.map { unsafe String(cString: $0) } ?? "text/plain"
        items.append(TerminalClipboardItem(mime: mime, text: TerminalClipboardRequests.string(item)))
    }
    guard !items.isEmpty else { return }
    let location: TerminalPasteboardLocation = clipboard == GHOSTTY_CLIPBOARD_SELECTION ? .selection : .standard
    // SAFETY: a surface's userdata (above).
    let bridge = unsafe SurfaceBridge.from(userdata)
    let run: @MainActor @Sendable () -> Void = {
        bridge?.writeClipboard(items: items, location: location, requiresConfirmation: confirm)
    }
    if Thread.isMainThread {
        // main-proof: guarded by Thread.isMainThread above
        MainActor.assumeIsolated(run)
    } else {
        MainRunLoopBlock.perform(run)
    }
}

nonisolated func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    // SAFETY: a surface's userdata (above).
    guard let bridge = unsafe SurfaceBridge.from(userdata) else { return }
    // Never inline, even on main: closing frees the surface, which must not happen inside its own callback.
    MainRunLoopBlock.perform { bridge.requestClose() }
}

/// `ghostty_surface_vsync_wanted_cb` (ghostty-next p03-rendering-082), set in a surface's config when it runs on
/// external vsync (``SurfaceBridge/setExternalVSync(in:userdata:)``): on the surface's renderer thread, on each
/// edge of whether it wants ticks. `userdata` is the surface's bridge, released only after ghostty_surface_free
/// returns (and never when the view is freed off main), so its ``SurfaceBridge/vsync`` outlives every call. It
/// takes the pacer's lock briefly and arms its hub subscription (or its linkless deadline); it never waits for main
/// or calls into Ghostty.
nonisolated func ghosttySurfaceVSyncWanted(_ userdata: UnsafeMutableRawPointer?, _ wanted: Bool) {
    // SAFETY: a surface's `vsync_userdata`, its bridge (above).
    unsafe SurfaceBridge.from(userdata)?.vsync.wantedChanged(wanted)
}

#if GHOSTTY_EXTERNAL_CURSOR
/// `ghostty_surface_cursor_cb` (ghostty-next p03-rendering-090), set in a surface's config while its view shows
/// the cursor itself (``TerminalCursorLayer``): once per move or change of the cursor cell, never per blink, inside
/// the Core Animation transaction that presents the cell's frame, on the thread that presents it (main, or the GPU
/// completion thread for a content-only frame). `userdata` is the surface's ``SurfaceBridge`` (`cursor_userdata`),
/// which outlives the surface. The cell goes on its layer in that transaction (``TerminalCursorPresenter``), so it
/// moves with its text; the blink follows in one coalesced main turn. It never blocks or calls into Ghostty, as
/// ghostty.h requires.
// perf-hot: 5us terminal-key (one published cell: three layer property sets, two atomics, at most one main wake)
nonisolated func ghosttySurfaceCursor(_ userdata: UnsafeMutableRawPointer?, _ cell: UnsafePointer<ghostty_cursor_cell_s>?) {
    // SAFETY: a surface's `cursor_userdata`, its SurfaceBridge (above); Ghostty passes one cell, valid for this
    // callback, which is copied before it returns.
    guard let bridge = unsafe SurfaceBridge.from(userdata), let presenter = bridge.cursor,
          let cell = unsafe cell?.pointee else { return }
    guard presenter.present(TerminalCursorState(cell)) else { return }
    MainRunLoopBlock.perform { bridge.view?.cursorCellsDidChange() }
}

extension TerminalCursorState {
    /// Copies Ghostty's cell; the cell's IOSurface is retained here (Ghostty passes it +0, valid for the call).
    nonisolated init(_ cell: ghostty_cursor_cell_s) {
        let style: Style = switch cell.style {
        case GHOSTTY_CURSOR_CELL_BLOCK_HOLLOW: .blockHollow
        case GHOSTTY_CURSOR_CELL_BAR: .bar
        case GHOSTTY_CURSOR_CELL_UNDERLINE: .underline
        case GHOSTTY_CURSOR_CELL_LOCK: .lock
        default: .block
        }
        // SAFETY: Ghostty's `surface` is an IOSurfaceRef (toll-free bridged to IOSurface) valid for this callback;
        // taking it unretained and storing it retains it, so it outlives the callback.
        let image = unsafe cell.surface.map { unsafe Image(surface: Unmanaged<IOSurface>.fromOpaque($0).takeUnretainedValue()) }
        self.init(serial: cell.serial,
                  cell: CGRect(x: Double(cell.x), y: Double(cell.y), width: Double(cell.width), height: Double(cell.height)),
                  style: style, visible: cell.visible, blinking: cell.blinking, blinkIntervalMS: cell.blink_interval_ms,
                  image: image)
    }
}
#endif
