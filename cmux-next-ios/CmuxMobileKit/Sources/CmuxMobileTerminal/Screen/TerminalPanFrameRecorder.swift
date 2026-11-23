#if os(iOS)
import CmuxMobileDesign
import QuartzCore

/// Times every display frame of one pan of the terminal, in every build (Release too), and
/// hands the pan to `onPan` when it ends, for the session to send to the Mac
/// (``TerminalPanFrames``). It listens to the shared ``FrameClock`` only between ``begin(_:)``
/// and ``finish()``: the screen calls `finish` when the drag and its fling end, when the
/// screen goes away, and it stops itself after ``TerminalPanFrames/maxFrames`` frames, so the
/// display link never runs for it outside a pan. Each frame costs one array append.
@MainActor
final class TerminalPanFrameRecorder {
    var onPan: ((TerminalPanFrames) -> Void)?
    private var token: FrameClock.Token?
    private var kind: TerminalPanFrames.Kind = .scrollback
    private var tally = TerminalPanFrameTally()

    var isRecording: Bool { token != nil }

    /// Starts a pan of `kind` over a page of `rows` rows; a pan still recording ends first.
    func begin(_ kind: TerminalPanFrames.Kind, rows: Int) {
        finish()
        self.kind = kind
        tally.rows = rows
        token = FrameClock.shared.subscribe { [weak self] tick in
            guard let self else { return }
            if self.tally.tick(timestamp: tick.timestamp, nominal: tick.nominal) { self.finish() }
        }
    }

    /// Terminal output arrived: counted only while a pan records.
    func output(_ bytes: Int) {
        if token != nil { tally.output(bytes) }
    }

    /// Ends the pan, if one records (of `kind`, when given), and hands it over.
    func finish(_ only: TerminalPanFrames.Kind? = nil) {
        guard let token, only == nil || only == kind else { return }
        FrameClock.shared.unsubscribe(token)
        self.token = nil
        let pan = tally.take(kind)
        onPan?(pan)
    }

    isolated deinit {
        if let token { FrameClock.shared.unsubscribe(token) }
    }
}
#endif
