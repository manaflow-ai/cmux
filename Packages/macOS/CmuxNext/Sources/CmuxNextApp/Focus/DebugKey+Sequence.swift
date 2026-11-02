#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextControl
import CmuxNextSettings

/// `debug.key {"sequence": [...]}` (DEBUG builds): a keyboard's raw
/// transitions, in order and with their gaps, as a remapper such as
/// Karabiner's virtual keyboard sends them (Leo 2026-10-12: left_command,
/// left_shift, close_bracket, ~5 ms apart; left_control, then tab ~270 ms
/// later, held ~175 ms). Each step is a virtual key code going down or up;
/// a modifier key is a flags-changed event (``DebugKeySequence``). Every event is built as a
/// `CGEvent` from the key code and the held modifiers, so the system layout
/// fills in its characters as for hardware (Shift-] types "}"), and is
/// posted to this app's event queue: it takes the path a real key does
/// (`nextEvent`, local monitors, `sendEvent`, the key window). Never posts
/// to another process.
///
/// `"key_window": "shell"` or `"page"` (with `pane`, default the focused pane) first makes that
/// window the app's key window, without activating the app (as `debug.window.focus` does): the shell
/// window for a terminal, or the Chromium page window of the pane's selected page, as when a person
/// clicked into the page, so the keys take the path a key in a focused page takes. Without it the
/// keys go to whatever window is key (with `CMUX_NEXT_NO_ACTIVATE=1`, none).
///
/// The sequence starts when this call runs (`base_s` in the reply, in `NSEvent.timestamp`'s seconds
/// since boot), and each event's timestamp is its intended press time, the base plus its offset,
/// whenever the main thread gets to post it (`player`, `AppControl`'s ``DebugKeySequencePlayer``).
/// Returns at once with the number of steps scheduled, the base, the duration (the last lands after
/// the sum of the gaps) and the key window. A new sequence cancels the one playing.
extension DebugKey {
    @MainActor static func sendSequence(_ params: [String: JSONValue], services: AppServices, player: DebugKeySequencePlayer) -> JSONValue {
        guard let steps = params["sequence"]?.arrayValue, let sequence = DebugKeySequence(steps) else {
            return .object(["error": .string("each step needs key_code and down")])
        }
        var keyWindow: JSONValue = .null
        if let wanted = params["key_window"]?.stringValue {
            if let refusal = makeKey(wanted, params, services: services) { return .object(["error": .string(refusal)]) }
            keyWindow = .string(wanted)
        }
        // The start in the event system's own units (``DebugKeySequence/Stamp``): the probe's, else the host clock.
        let source = CGEventSource(stateID: .privateState), probe = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        guard let stamp = DebugKeySequence.Stamp.start(probeTimestamp: probe?.timestamp ?? 0,
                                                       probeSeconds: probe.flatMap { NSEvent(cgEvent: $0)?.timestamp }) else {
            return .object(["error": .string("no event timestamp to start the sequence from")])
        }
        let baseSeconds = Double(stamp.base) / stamp.ticksPerSecond
        player.play(sequence, stamp: stamp, source: source, clock: ContinuousClock()) { cgEvent in
            if let event = NSEvent(cgEvent: cgEvent) { NSApp.postEvent(event, atStart: false) }
        }
        return .object(["scheduled": .number(Double(sequence.steps.count)), "base_s": .number(baseSeconds),
                        "duration_ms": .number(sequence.durationSeconds * 1000), "key_window": keyWindow])
    }

    /// Makes the `wanted` window (`shell`, or the `page` window of `params["pane"]` or the focused
    /// pane) of `params["window"]` (default: the active window) the app's key window without
    /// activating the app; returns why it could not, or nil.
    @MainActor private static func makeKey(_ wanted: String, _ params: [String: JSONValue], services: AppServices) -> String? {
        let windowID = params["window"]?.stringValue
        let controller = windowID.map { id in services.windows.controllers.first { $0.state.id == id } } ?? services.windows.active
        guard let controller, let shell = controller.window else { return "no window" }
        let window: NSWindow
        switch wanted {
        case "shell":
            window = shell
        case "page":
            guard let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
                  let page = pageWindow(of: pane, in: controller) else { return "no Chromium page window for pane" }
            window = page
        default:
            return "key_window must be shell or page"
        }
        shell.orderFrontRegardless()
        window.makeKey()
        return NSApp.keyWindow === window ? nil : "the \(wanted) window did not become key"
    }
}
#endif
