/// Decides which typed characters cmux may draw before the remote echoes them.
///
/// The engine owns policy, not pixels. It never writes to the terminal grid, so
/// a wrong guess is withdrawn by dropping an overlay glyph rather than by
/// undoing a screen mutation, and the authoritative screen stays whatever the
/// remote said it was.
///
/// Prediction runs only inside a confirmed echo run: the engine will not draw a
/// character until it has seen the remote echo a character it tracked, and any
/// output it did not predict ends the run. A password prompt therefore never
/// displays a speculative glyph, because nothing there is ever echoed.
///
/// Backspace over a glyph the remote has not echoed yet retracts it from the
/// overlay at once. The remote still receives both keystrokes, so it echoes
/// the character and then erases it; the engine waits for exactly that and
/// withdraws on anything else. Backspace over anything the remote already
/// drew is the remote's to render, and withdraws as any other editing key.
public struct TerminalPredictionEngine: Sendable {
    public enum Status: Sendable, Equatable {
        /// The setting is off.
        case disabled
        /// No confirmed echo yet, or the last remote output ended the run.
        /// Keystrokes are tracked so an echo can re-arm, but nothing is drawn.
        case listening
        /// The link is fast enough that there is no lag to hide.
        case linkIsFastEnough
        /// A full-screen application owns the screen; its echo is unpredictable.
        case alternateScreen
        /// Too many visible withdrawals recently.
        case suspended
        case predicting
    }

    /// How far through erasing one retracted glyph the remote's echo is.
    ///
    /// Line editors erase one character as a move left followed by a clear:
    /// `BS SP BS`, `BS CSI K`, `BS CSI P`, or `CSI D` in place of `BS`.
    private enum EraseProgress: Sendable, Equatable {
        case awaitingMoveLeft
        /// On the retracted glyph's cell, one left of where the echo left the
        /// cursor.
        case movedLeft
        /// Printed a space over it, so the cursor is back where it started.
        case blanked
    }

    private enum Keystroke: Sendable, Equatable {
        /// A printable key: the remote echoes `byte` and advances one cell.
        case glyph(Character, byte: UInt8)
        /// A Backspace that retracted the newest glyph before it.
        case erase(EraseProgress)
    }

    /// One keystroke the remote has not finished echoing, in the order sent.
    ///
    /// The remote echoes these strictly in order, so the ones it has echoed
    /// are always a prefix of the queue.
    private struct Entry: Sendable {
        var keystroke: Keystroke
        let typedAt: PredictionInstant
        /// For a glyph, whether its echo arrived. An erase stays speculative
        /// until it completes, and then leaves the queue with its glyph.
        var standing: PredictedGlyph.Standing
        /// When the echo arrived. The hold is measured from here, not from the
        /// keystroke, so a slow link does not expire its own confirmations.
        /// Never set on a retracted glyph, which has nothing to hold.
        var confirmedAt: PredictionInstant?
        /// Whether the user ever saw this glyph. Only these can misfire
        /// visibly, so only these count toward suspension.
        let isDisplayed: Bool
        /// A later Backspace took it back. The remote still echoes it, but
        /// the overlay never draws it again.
        var isRetracted = false

        var isDrawn: Bool { isDisplayed && !isRetracted }

        /// Cells this keystroke moves the cursor once fully echoed.
        var cellAdvance: Int {
            switch keystroke {
            case .glyph: 1
            case .erase: -1
            }
        }

        /// Cells the echo received so far has moved the cursor.
        var echoedAdvance: Int {
            switch keystroke {
            case .glyph: standing == .confirmed ? 1 : 0
            case .erase(.movedLeft): -1
            case .erase(.awaitingMoveLeft), .erase(.blanked): 0
            }
        }

        var isHeldConfirmation: Bool {
            guard case .glyph = keystroke else { return false }
            return standing == .confirmed && !isRetracted
        }
    }

    public var configuration: PredictionConfiguration
    public var isEnabled: Bool

    private var scanner = TerminalOutputScanner()
    private var entries: [Entry] = []
    private var isAlternateScreen = false
    /// Set by the first confirmed echo, cleared by any output we did not
    /// predict. Gates display entirely.
    private var isEchoRunActive = false
    private var smoothedEchoLatency: Duration?
    private var recentMispredictions: [PredictionInstant] = []
    private var suspendedUntil: PredictionInstant?
    /// Until this instant, output may still be the echo of keystrokes the
    /// engine stopped tracking when it last withdrew. Matching that echo
    /// against keystrokes typed since would misalign every later offset, so
    /// until it passes, output only clears the queue.
    private var untrackedEchoDeadline: PredictionInstant?

    public init(
        configuration: PredictionConfiguration = .default,
        isEnabled: Bool = false
    ) {
        self.configuration = configuration
        self.isEnabled = isEnabled
    }

    // MARK: Readable state

    /// What the host should draw, ordered left to right, with offsets measured
    /// from the live cursor.
    ///
    /// The host anchors on the cursor ghostty reports, and ghostty's parser
    /// has already advanced that cursor past every echo this engine has
    /// confirmed (the tee runs ahead of the parser, and the engine drains
    /// after it). So confirmed glyphs, which are always the leading entries,
    /// sit at negative offsets, exactly over the cells their echo landed in:
    /// drawing them there covers the frames before ghostty repaints without
    /// ever doubling a character one cell to the right. Speculative glyphs
    /// start at offset 0. Entries typed before the run armed are never drawn,
    /// but still occupy their cell, so a later glyph keeps its true offset.
    ///
    /// A retracted glyph and its erase add up to no cells, but while the
    /// remote is between echoing the character and erasing it the live
    /// cursor sits one cell further right, so offsets are measured from how
    /// far the echo so far has actually moved it.
    public var glyphs: [PredictedGlyph] {
        let cursor = entries.reduce(0) { $0 + $1.echoedAdvance }
        var cell = 0
        var drawn: [PredictedGlyph] = []
        for entry in entries {
            if entry.isDrawn, case .glyph(let character, _) = entry.keystroke {
                drawn.append(PredictedGlyph(
                    character: character,
                    offset: cell - cursor,
                    standing: entry.standing
                ))
            }
            cell += entry.cellAdvance
        }
        return drawn
    }

    /// Round trip from keystroke to echo, smoothed. `nil` until the first echo.
    public var observedEchoLatency: Duration? { smoothedEchoLatency }

    /// When the next change to what is drawn falls due, or `nil` when
    /// nothing is drawn.
    ///
    /// Nothing renders a terminal that has gone quiet, so the host has to set
    /// a timer for this; otherwise a prediction made just before the link died
    /// would stay drawn until the user typed again. Any speculative entry
    /// expiring withdraws everything, so while anything is drawn the undrawn
    /// ones count too: an erase that never arrives expires on its own
    /// keystroke's clock, not on that of a glyph typed after it.
    public var nextExpiry: PredictionInstant? {
        guard entries.contains(where: \.isDrawn) else { return nil }
        return entries.compactMap { entry -> PredictionInstant? in
            if entry.standing == .speculative {
                return entry.typedAt + configuration.speculativeLifetime
            }
            guard entry.isDrawn, let confirmedAt = entry.confirmedAt else { return nil }
            return confirmedAt + configuration.confirmationHold
        }.min()
    }

    public func status(at now: PredictionInstant) -> Status {
        guard isEnabled else { return .disabled }
        if isAlternateScreen { return .alternateScreen }
        if let until = suspendedUntil, now < until { return .suspended }
        guard isEchoRunActive else { return .listening }
        guard let latency = smoothedEchoLatency else { return .listening }
        guard latency > configuration.engageAboveEchoLatency else { return .linkIsFastEnough }
        return .predicting
    }

    /// Seeds whether a full-screen application already owns the screen.
    ///
    /// The engine otherwise learns this only from the mode switches it sees
    /// in output, so a surface that was already in the alternate screen when
    /// prediction started (the setting turned on, or the surface registered,
    /// with vim or htop open) would predict inside it. The host reads the
    /// terminal's current mode and passes it here before anything is typed.
    public mutating func seedAlternateScreen(_ isActive: Bool) {
        isAlternateScreen = isActive
    }

    // MARK: Input

    /// Record what the user typed. `text` is the literal bytes cmux is about to
    /// send to the PTY. Returns whether the drawn overlay changed.
    @discardableResult
    public mutating func typed(_ text: String, at now: PredictionInstant) -> Bool {
        if Self.isLoneBackspace(text) { return typedBackspace(at: now) }
        return typed(printableASCII: Self.lonePrintableASCII(text), at: now)
    }

    /// The byte-level entry point the host uses.
    ///
    /// Separate from `typed(_:at:)` because this runs on every keystroke, and
    /// building a `String` there to immediately reduce it to one byte is an
    /// allocation on the typing path.
    ///
    /// - Parameter byte: The printable ASCII byte this key sends, or `nil` for
    ///   every other key but Backspace, which goes to `typedBackspace(at:)`.
    ///   `nil` withdraws: editing keys, Return, chords, and
    ///   anything the key encoder turned into an escape sequence all leave the
    ///   screen somewhere this does not model, and non-ASCII text can be wide
    ///   or combining, so its cell count is not one.
    @discardableResult
    public mutating func typed(printableASCII byte: UInt8?, at now: PredictionInstant) -> Bool {
        guard isEnabled else { return false }
        let expired = expire(at: now)

        guard let byte, (0x20...0x7E).contains(byte) else {
            return withdrawAll(countingMisprediction: false, at: now, sendingKeystroke: true) || expired
        }
        guard entries.count < configuration.maximumSpeculativeGlyphs else {
            return withdrawAll(countingMisprediction: false, at: now, sendingKeystroke: true) || expired
        }
        if let deadline = untrackedEchoDeadline, now < deadline {
            // Readline and zle redraw pending input as one net change, so
            // this key's echo may arrive merged with the untracked ones, or
            // not at all when it undoes one of them. Matching it would re-arm
            // a run cells away from the remote, so it is untracked too.
            untrackedEchoDeadline = max(deadline, now + untrackedEchoSettle)
            return expired
        }

        let display = status(at: now) == .predicting
        entries.append(Entry(
            keystroke: .glyph(Character(UnicodeScalar(byte)), byte: byte),
            typedAt: now,
            standing: .speculative,
            confirmedAt: nil,
            isDisplayed: display
        ))
        return display || expired
    }

    /// Record a Backspace, whichever byte (DEL or BS) the key sends.
    ///
    /// Retracts the newest glyph if it is drawn and the remote has not echoed
    /// it; the remote's echo of it, and of its erase, is then expected before
    /// anything else. With no such glyph, the character to erase is already
    /// on the grid, or was never shown, so this withdraws like any other
    /// editing key. Returns whether the drawn overlay changed.
    @discardableResult
    public mutating func typedBackspace(at now: PredictionInstant) -> Bool {
        guard isEnabled else { return false }
        let expired = expire(at: now)

        // Everything after the newest unretracted glyph is retracted glyphs
        // and their erases, which occupy no cells, so it is the one the
        // remote will erase.
        guard let index = entries.lastIndex(where: {
                  if case .glyph = $0.keystroke { return !$0.isRetracted }
                  return false
              }),
              entries[index].isDrawn,
              entries[index].standing == .speculative,
              entries.count < configuration.maximumSpeculativeGlyphs
        else {
            return withdrawAll(countingMisprediction: false, at: now, sendingKeystroke: true) || expired
        }

        entries[index].isRetracted = true
        entries.append(Entry(
            keystroke: .erase(.awaitingMoveLeft),
            typedAt: now,
            standing: .speculative,
            confirmedAt: nil,
            isDisplayed: false
        ))
        return true
    }

    /// Feed the bytes the remote sent, from the PTY output tee. Returns whether
    /// the host has to re-anchor the overlay.
    ///
    /// That is not only when the drawn set changed. Every offset is measured
    /// from the live cursor, so any output that moves it while something is
    /// drawn moves every drawn glyph too, even an echo nobody saw typed. The
    /// host may also have re-anchored on a frame ghostty rendered after
    /// parsing this output but before this drain, measuring the old offsets
    /// from the new cursor; only a redraw now puts them back.
    @discardableResult
    public mutating func observedOutput(_ bytes: some Sequence<UInt8>, at now: PredictionInstant) -> Bool {
        let signals = scanner.scan(bytes)
        guard isEnabled else { return false }
        var changed = expire(at: now)
        var movedCursor = false
        for signal in signals {
            if signal != .ignorable { movedCursor = true }
            if let deadline = untrackedEchoDeadline {
                if now < deadline, signal != .ignorable, !Self.isAlternateScreen(signal) {
                    // Possibly the echo of a keystroke already given up on.
                    // Drop what was typed since as well: its echo is behind
                    // output this cannot account for.
                    changed = withdrawAll(countingMisprediction: false, at: now) || changed
                    continue
                }
                if now >= deadline { untrackedEchoDeadline = nil }
            }
            switch signal {
            case .ignorable:
                continue

            case .alternateScreen(let entered):
                isAlternateScreen = entered
                changed = withdrawAll(countingMisprediction: false, at: now) || changed

            case .disruptive:
                // The remote moved the screen somewhere we did not predict, so
                // every offset we are holding is now measured from the wrong
                // cursor. Where an erase was due, that is a shell erasing in a
                // form not modelled here, not a wrong guess.
                changed = withdrawAll(
                    countingMisprediction: !isAwaitingErase,
                    at: now
                ) || changed

            case .printable(let byte):
                changed = consumePrintable(byte, at: now) || changed

            case .cursorLeft, .clearAtCursor:
                changed = consumeErase(signal, at: now) || changed
            }
        }
        return changed || (movedCursor && entries.contains { $0.isDrawn })
    }

    /// Report that a rendered frame reached the screen. Confirmed glyphs retire
    /// here: the tee fires before the VT parser, so retiring at confirmation
    /// would blank the cell for the frames between the echo and its paint.
    @discardableResult
    public mutating func presentedFrame(at now: PredictionInstant) -> Bool {
        expire(at: now)
        let before = entries.count
        entries.removeAll { $0.isHeldConfirmation }
        return entries.count != before
    }

    /// Advance time with no other event, withdrawing anything that has aged out.
    @discardableResult
    public mutating func tick(at now: PredictionInstant) -> Bool {
        expire(at: now)
    }

    // MARK: Internals

    private mutating func consumePrintable(_ byte: UInt8, at now: PredictionInstant) -> Bool {
        guard let index = entries.firstIndex(where: { $0.standing == .speculative }) else {
            // Output at the cursor that we did not type. It advances the cursor
            // our offsets are measured from, and it ends the echo run.
            return withdrawAll(countingMisprediction: false, at: now)
        }
        guard now >= entries[index].typedAt else {
            // Output stamped before the keystroke existed was already in
            // flight when it was typed (arrivals drain later on the main
            // actor), so it cannot be the echo of it.
            return withdrawAll(countingMisprediction: false, at: now)
        }
        guard case .glyph(_, let expected) = entries[index].keystroke else {
            // Mid-erase, the only printable a line editor sends is the space
            // of `BS SP BS`; the erase withdraws on anything else.
            return advanceErase(at: index, by: .printable(byte), at: now)
        }
        guard expected == byte else {
            return withdrawAll(countingMisprediction: true, at: now)
        }

        record(echoLatency: now - entries[index].typedAt)
        isEchoRunActive = true
        if entries[index].isRetracted {
            // Its cell is the grid's until the erase arrives. Nothing is held,
            // but the cursor moved, so drawn glyphs are measured afresh.
            entries[index].standing = .confirmed
            return entries.contains { $0.isDrawn }
        }
        // A glyph the user never saw has nothing to hold on screen for; the
        // real character is already on its way into the grid. It still
        // counts toward the cursor for any held glyph before it, so it goes
        // when they do.
        guard entries[index].isDisplayed else {
            if entries[..<index].contains(where: \.isDrawn) {
                entries[index].standing = .confirmed
                entries[index].confirmedAt = now
            } else {
                entries.remove(at: index)
            }
            return false
        }
        entries[index].standing = .confirmed
        entries[index].confirmedAt = now
        return true
    }

    /// A cursor-left or clear from the remote, which only a pending erase
    /// expects. Anywhere else it moved the screen in a way we did not predict.
    private mutating func consumeErase(
        _ signal: TerminalOutputSignal,
        at now: PredictionInstant
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.standing == .speculative }) else {
            return withdrawAll(countingMisprediction: true, at: now)
        }
        guard now >= entries[index].typedAt else {
            // Already in flight when the key was typed, as in
            // `consumePrintable`: not its echo, and not a wrong guess.
            return withdrawAll(countingMisprediction: false, at: now)
        }
        guard case .erase = entries[index].keystroke else {
            return withdrawAll(countingMisprediction: true, at: now)
        }
        return advanceErase(at: index, by: signal, at: now)
    }

    /// Whether the next echo expected is (the rest of) an erase.
    private var isAwaitingErase: Bool {
        guard let next = entries.first(where: { $0.standing == .speculative }),
              case .erase = next.keystroke else { return false }
        return true
    }

    /// Advances the erase at `index`, the next echo expected.
    ///
    /// A mismatch withdraws without counting toward suspension. Line editors
    /// erase in more forms than the ones modelled here (a full repaint after
    /// a carriage return, zsh redrawing an autosuggestion), and a shell that
    /// always uses one of those is not mispredicting; counting it would
    /// suspend prediction after a few corrections.
    private mutating func advanceErase(
        at index: Int,
        by signal: TerminalOutputSignal,
        at now: PredictionInstant
    ) -> Bool {
        guard case .erase(let progress) = entries[index].keystroke else {
            return withdrawAll(countingMisprediction: false, at: now)
        }
        switch (progress, signal) {
        case (.awaitingMoveLeft, .cursorLeft):
            entries[index].keystroke = .erase(.movedLeft)
        case (.movedLeft, .printable(0x20)):
            entries[index].keystroke = .erase(.blanked)
        case (.movedLeft, .clearAtCursor), (.blanked, .cursorLeft):
            // Erased. Every inner retraction completed before this one, so
            // the entry just before it is the glyph it took back, and the
            // pair together occupies no cells.
            guard index > 0, entries[index - 1].isRetracted else {
                return withdrawAll(countingMisprediction: false, at: now)
            }
            entries.removeSubrange((index - 1)...index)
        default:
            return withdrawAll(countingMisprediction: false, at: now)
        }
        return entries.contains { $0.isDrawn }
    }

    private mutating func record(echoLatency sample: Duration) {
        guard let current = smoothedEchoLatency else {
            smoothedEchoLatency = sample
            return
        }
        smoothedEchoLatency = (current * 7 + sample) / 8
    }

    @discardableResult
    ///
    /// - Parameter sendingKeystroke: The withdrawal is for a key being sent
    ///   now, whose echo is as untracked as those of the entries dropped.
    private mutating func withdrawAll(
        countingMisprediction: Bool,
        at now: PredictionInstant,
        sendingKeystroke: Bool = false
    ) -> Bool {
        let wasVisible = entries.contains { $0.isDrawn }
        if countingMisprediction, wasVisible {
            recentMispredictions.append(now)
            recentMispredictions.removeAll { now - $0 > configuration.mispredictionWindow }
            if recentMispredictions.count >= configuration.mispredictionsBeforeSuspending {
                suspendedUntil = now + configuration.suspension
                recentMispredictions.removeAll()
            }
        }
        // Keystrokes still in flight echo anyway, in a form this no longer
        // tracks. Each echo arrives within about a round trip of its key, so
        // output keeps clearing the queue until that has passed for the
        // newest of them.
        let newestUntracked = sendingKeystroke
            ? now
            : entries.lazy.filter { $0.standing == .speculative }.map(\.typedAt).max()
        if let newestUntracked {
            let deadline = newestUntracked + untrackedEchoSettle
            untrackedEchoDeadline = max(untrackedEchoDeadline ?? deadline, deadline)
        }
        entries.removeAll()
        isEchoRunActive = false
        return wasVisible
    }

    /// How long after a withdrawal output may still belong to keystrokes the
    /// engine dropped. Twice the round trip absorbs jitter and a remote that
    /// reads in bursts; with no measurement yet, nothing is drawn anyway, so
    /// a generous default only delays arming.
    private var untrackedEchoSettle: Duration {
        guard let latency = smoothedEchoLatency else { return .milliseconds(500) }
        return latency * 2 + .milliseconds(50)
    }

    @discardableResult
    private mutating func expire(at now: PredictionInstant) -> Bool {
        if let until = suspendedUntil, now >= until { suspendedUntil = nil }

        let staleConfirmation = entries.contains {
            guard let confirmedAt = $0.confirmedAt else { return false }
            return now - confirmedAt > configuration.confirmationHold
        }
        if staleConfirmation {
            // The host stopped reporting frames. Drop the hold rather than leave
            // a glyph pinned over a cell the grid already owns.
            entries.removeAll {
                guard let confirmedAt = $0.confirmedAt else { return false }
                return now - confirmedAt > configuration.confirmationHold
            }
        }

        // Erases and retracted glyphs expire too: an echo that never comes
        // leaves every later offset measured from the wrong cell.
        let expiredSpeculation = entries.contains {
            $0.standing == .speculative && now - $0.typedAt > configuration.speculativeLifetime
        }
        guard expiredSpeculation else { return staleConfirmation }
        // Nothing came back. Whatever we drew was wrong, or the link stalled.
        return withdrawAll(countingMisprediction: true, at: now) || staleConfirmation
    }

    private static func isAlternateScreen(_ signal: TerminalOutputSignal) -> Bool {
        if case .alternateScreen = signal { return true }
        return false
    }

    /// DEL is what ghostty sends for Backspace by default; BS when configured.
    private static func isLoneBackspace(_ text: String) -> Bool {
        var iterator = text.utf8.makeIterator()
        guard let byte = iterator.next(), iterator.next() == nil else { return false }
        return byte == 0x7F || byte == 0x08
    }

    private static func lonePrintableASCII(_ text: String) -> UInt8? {
        var iterator = text.utf8.makeIterator()
        guard let byte = iterator.next(), iterator.next() == nil else { return nil }
        guard (0x20...0x7E).contains(byte) else { return nil }
        return byte
    }
}
