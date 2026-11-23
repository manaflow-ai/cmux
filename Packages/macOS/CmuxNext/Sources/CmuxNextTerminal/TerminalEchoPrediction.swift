import CCmuxTerminalPredictionFFI
import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import QuartzCore

/// One terminal's predictive local echo engine: the shared Rust engine
/// (`cmux-terminal-prediction`, `cmux_terminal_prediction_*` over the app FFI)
/// behind a Sendable handle.
///
/// The decisions are all the engine's: which typed characters to draw before
/// the remote echoes them, when an echo confirms them, when a mismatch takes
/// them back, and when not to predict at all (a fast link, a password prompt, a
/// full-screen program, too many recent withdrawals). This class only carries
/// the calls. They come from three threads, as the engine allows: input on
/// Ghostty's IO thread (``sent(_:)``), output on the output lane after Ghostty
/// parsed it (``output(_:)``, ``missedOutput(alternateScreen:)``), frames and
/// the overlay on the main thread.
///
/// A call whose answer means the overlay must be drawn again asks for one main
/// actor redraw (``onRedraw``); asks before that redraw runs share it, so a
/// busy terminal costs the main thread at most one hop per turn, and none while
/// nothing is drawn and the engine answers no.
nonisolated final class TerminalEchoPrediction: Sendable {
    /// One cell the overlay draws.
    struct Glyph: Equatable, Sendable {
        enum Standing: UInt8, Sendable {
            /// Typed, not echoed yet: underlined.
            case speculative = 0
            /// Echoed, held until the frame that shows the echo is on screen: plain.
            case confirmed = 1
            /// A predicted delete: the cell's background only.
            case erased = 2
        }

        var character: UInt8
        var standing: Standing
        /// Cells right of the live cursor; negative for a held confirmation.
        var offset: Int32
    }

    /// The run on the cursor row the overlay draws.
    struct Layout: Equatable, Sendable {
        /// The run's first cell, in cells from the live cursor.
        var leadingOffset: Int32
        var cellCount: Int32
        /// Where typing continues, in cells from the live cursor (nil: no caret).
        var caretOffset: Int32?
        var glyphs: [Glyph]
    }

    /// Why the engine is or is not drawing (`cmux_terminal_prediction_status`).
    enum Status: UInt8, Sendable {
        case disabled = 0, localSurface, listening, linkFastEnough, alternateScreen, suspended, predicting
    }

    /// The engine handle's address (0: none): an integer, so the class stays checked Sendable; the C ABI locks the
    /// engine's mutex for each call, whatever the thread.
    private let address: UInt
    private var handle: OpaquePointer? { OpaquePointer(bitPattern: address) }
    /// Whether the overlay shows glyphs now: while it does, every event redraws.
    private let drawing = Atomic<Bool>(false)
    /// A redraw is queued on the main actor and has not run yet.
    private let redrawQueued = Atomic<Bool>(false)
    /// Frames presented by the surface layer this engine watches (tests read it).
    private let frames = Atomic<UInt64>(0)
    /// The main actor's redraw (``TerminalEchoPredictor/refresh()``).
    private let redraw = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    /// `remote`: the terminal's shell runs on another machine (``TerminalIO/predictsEcho``).
    init(enabled: Bool, remote: Bool) {
        address = UInt(bitPattern: cmux_terminal_prediction_new(enabled, remote))
    }

    deinit {
        cmux_terminal_prediction_free(handle)
    }

    /// Microseconds of the one monotonic clock every call uses.
    static func now() -> UInt64 {
        UInt64(max(0, CACurrentMediaTime()) * 1_000_000)
    }

    // MARK: Events (any thread)

    /// One write of encoded input about to go to the remote (Ghostty's `io_write_cb`).
    func sent(_ bytes: Data) {
        let changed = bytes.withUnsafeBytes { raw in
            cmux_terminal_prediction_sent(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Self.now())
        }
        askRedraw(changed)
    }

    /// Output the remote sent, right after Ghostty parsed it on the output lane (same bytes, same order), so the
    /// overlay reads a cursor that already moved for every byte the engine saw.
    func output(_ bytes: Data) {
        let changed = bytes.withUnsafeBytes { raw in
            cmux_terminal_prediction_output(handle, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, Self.now())
        }
        askRedraw(changed)
    }

    /// The screen was replaced rather than written (a replay, a snapshot restore, a new grid): everything starts
    /// over, and `alternateScreen` (read from the surface after the restore) says whether a full-screen program owns it.
    func missedOutput(alternateScreen: Bool?) {
        let changed = cmux_terminal_prediction_missed_output(handle, Self.now())
        if let alternateScreen { cmux_terminal_prediction_seed_alternate_screen(handle, alternateScreen) }
        askRedraw(changed)
    }

    /// A binary snapshot replaced the screen (a reattach): everything starts over as for ``missedOutput(alternateScreen:)``,
    /// and since the snapshot's pen is not readable, the engine treats it as concealing until output reveals it (an SGR
    /// reset, as every prompt redraw sends). A reattach to `cat` after `printf '\033[8m'` then draws nothing.
    func restoredSnapshot(alternateScreen: Bool?) {
        missedOutput(alternateScreen: alternateScreen)
        let concealUntilRevealed: [UInt8] = [0x1B, 0x5B, 0x38, 0x6D]
        let changed = concealUntilRevealed.withUnsafeBufferPointer { buffer in
            cmux_terminal_prediction_output(handle, buffer.baseAddress, buffer.count, Self.now())
        }
        askRedraw(changed)
    }

    /// The grid changed under the glyphs with no output lost (a resize): what is drawn goes, and what the engine knows
    /// of the screen and its pen stays.
    func layoutChanged() {
        askRedraw(cmux_terminal_prediction_layout_changed(handle, Self.now()))
    }

    /// A frame of the surface reached its layer: held confirmations retire.
    func presentedFrame() {
        _ = frames.add(1, ordering: .relaxed)
        askRedraw(cmux_terminal_prediction_presented_frame(handle, Self.now()))
    }

    /// Seeds whether a full-screen program already owns the screen (a surface made or swapped in).
    func seedAlternateScreen(_ active: Bool) {
        cmux_terminal_prediction_seed_alternate_screen(handle, active)
    }

    /// Turns prediction on or off (a fresh engine either way). Answers whether anything drawn went.
    @discardableResult
    func set(enabled: Bool, remote: Bool) -> Bool {
        cmux_terminal_prediction_set(handle, enabled, remote)
    }

    var presentedFrames: UInt64 { frames.load(ordering: .relaxed) }

    // MARK: The overlay (main actor)

    /// The main actor's redraw for every event whose answer changes what is drawn.
    func onRedraw(_ body: (@MainActor @Sendable () -> Void)?) {
        redraw.store(body)
    }

    /// Whether the overlay shows glyphs now (set by the overlay's owner after each draw).
    func setDrawing(_ shows: Bool) {
        drawing.store(shows, ordering: .relaxed)
    }

    /// Time passed with no other event: withdraws what aged out.
    @discardableResult
    func tick() -> Bool {
        cmux_terminal_prediction_tick(handle, Self.now())
    }

    /// When the next change to what is drawn falls due (this clock's microseconds), nil when nothing is drawn.
    var nextExpiry: UInt64? {
        var due: UInt64 = 0
        return cmux_terminal_prediction_next_expiry(handle, &due) ? due : nil
    }

    /// Output took away blanks the frame on screen still shows: the overlay stays as it is until the next frame.
    var holdsLayout: Bool {
        cmux_terminal_prediction_holds_layout(handle)
    }

    var status: Status {
        Status(rawValue: cmux_terminal_prediction_status(handle, Self.now())) ?? .disabled
    }

    /// The smoothed keystroke-to-echo round trip in microseconds, nil before the first echo.
    var echoLatency: UInt64? {
        var latency: UInt64 = 0
        return cmux_terminal_prediction_echo_latency(handle, &latency) ? latency : nil
    }

    /// What to draw now on a row of `columns` cells with the live cursor at `cursorColumn`; nil: nothing.
    func layout(cursorColumn: Int, columns: Int) -> Layout? {
        guard columns > 0 else { return nil }
        var layout = CmuxPredictionLayout()
        var glyphs = [CmuxPredictedGlyph](repeating: CmuxPredictedGlyph(), count: columns)
        let drawn = glyphs.withUnsafeMutableBufferPointer { buffer in
            cmux_terminal_prediction_layout(handle, Self.now(), Int32(clamping: cursorColumn), Int32(clamping: columns),
                                            &layout, buffer.baseAddress, buffer.count)
        }
        guard drawn else { return nil }
        return Layout(
            leadingOffset: layout.leading_offset,
            cellCount: layout.cell_count,
            caretOffset: layout.has_caret ? layout.caret_offset : nil,
            glyphs: glyphs.prefix(min(layout.glyph_count, glyphs.count)).map { glyph in
                Glyph(character: glyph.character, standing: Glyph.Standing(rawValue: glyph.standing) ?? .speculative,
                      offset: glyph.offset)
            })
    }

    // MARK: Redraw

    /// One main actor redraw for an answer that changed what is drawn, or for any event while glyphs show.
    private func askRedraw(_ changed: Bool) {
        guard changed || drawing.load(ordering: .relaxed) else { return }
        guard !redrawQueued.exchange(true, ordering: .acquiringAndReleasing) else { return }
        // Always a later turn, never inline: Ghostty sends a mouse report from inside its input callback while it holds
        // the renderer lock, and the redraw reads grid metrics, which take that lock too.
        MainDelivery().later { [self] in
            redrawQueued.store(false, ordering: .releasing)
            redraw.load()?()
        }
    }
}
