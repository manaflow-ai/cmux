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

    private struct Entry: Sendable {
        let character: Character
        let byte: UInt8
        let typedAt: PredictionInstant
        var standing: PredictedGlyph.Standing
        /// When the echo arrived. The hold is measured from here, not from the
        /// keystroke, so a slow link does not expire its own confirmations.
        var confirmedAt: PredictionInstant?
        /// Whether the user ever saw this glyph. Only these can misfire
        /// visibly, so only these count toward suspension.
        let isDisplayed: Bool
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
    public var glyphs: [PredictedGlyph] {
        let consumedByCursor = entries.prefix { $0.standing == .confirmed }.count
        return entries.enumerated().compactMap { index, entry in
            guard entry.isDisplayed else { return nil }
            return PredictedGlyph(
                character: entry.character,
                offset: index - consumedByCursor,
                standing: entry.standing
            )
        }
    }

    /// Round trip from keystroke to echo, smoothed. `nil` until the first echo.
    public var observedEchoLatency: Duration? { smoothedEchoLatency }

    /// When the oldest glyph on screen ages out, or `nil` when none is.
    ///
    /// Nothing renders a terminal that has gone quiet, so the host has to set
    /// a timer for this; otherwise a prediction made just before the link died
    /// would stay drawn until the user typed again.
    public var nextExpiry: PredictionInstant? {
        entries.compactMap { entry -> PredictionInstant? in
            guard entry.isDisplayed else { return nil }
            if let confirmedAt = entry.confirmedAt {
                return confirmedAt + configuration.confirmationHold
            }
            return entry.typedAt + configuration.speculativeLifetime
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

    // MARK: Input

    /// Record what the user typed. `text` is the literal bytes cmux is about to
    /// send to the PTY. Returns whether the drawn overlay changed.
    @discardableResult
    public mutating func typed(_ text: String, at now: PredictionInstant) -> Bool {
        typed(printableASCII: Self.lonePrintableASCII(text), at: now)
    }

    /// The byte-level entry point the host uses.
    ///
    /// Separate from `typed(_:at:)` because this runs on every keystroke, and
    /// building a `String` there to immediately reduce it to one byte is an
    /// allocation on the typing path.
    ///
    /// - Parameter byte: The printable ASCII byte this key sends, or `nil` for
    ///   every other key. `nil` withdraws: editing keys, Return, chords, and
    ///   anything the key encoder turned into an escape sequence all leave the
    ///   screen somewhere this does not model, and non-ASCII text can be wide
    ///   or combining, so its cell count is not one.
    @discardableResult
    public mutating func typed(printableASCII byte: UInt8?, at now: PredictionInstant) -> Bool {
        guard isEnabled else { return false }
        expire(at: now)

        guard let byte, (0x20...0x7E).contains(byte) else {
            return withdrawAll(countingMisprediction: false)
        }
        guard entries.count < configuration.maximumSpeculativeGlyphs else {
            return withdrawAll(countingMisprediction: false)
        }

        let display = status(at: now) == .predicting
        entries.append(Entry(
            character: Character(UnicodeScalar(byte)),
            byte: byte,
            typedAt: now,
            standing: .speculative,
            confirmedAt: nil,
            isDisplayed: display
        ))
        return display
    }

    /// Feed the bytes the remote sent, from the PTY output tee. Returns whether
    /// the drawn overlay changed.
    @discardableResult
    public mutating func observedOutput(_ bytes: some Sequence<UInt8>, at now: PredictionInstant) -> Bool {
        let signals = scanner.scan(bytes)
        guard isEnabled else { return false }
        expire(at: now)

        var changed = false
        for signal in signals {
            switch signal {
            case .ignorable:
                continue

            case .alternateScreen(let entered):
                isAlternateScreen = entered
                changed = withdrawAll(countingMisprediction: false) || changed

            case .disruptive:
                // The remote moved the screen somewhere we did not predict, so
                // every offset we are holding is now measured from the wrong
                // cursor.
                changed = withdrawAll(countingMisprediction: true, at: now) || changed

            case .printable(let byte):
                changed = consumePrintable(byte, at: now) || changed
            }
        }
        return changed
    }

    /// Report that a rendered frame reached the screen. Confirmed glyphs retire
    /// here: the tee fires before the VT parser, so retiring at confirmation
    /// would blank the cell for the frames between the echo and its paint.
    @discardableResult
    public mutating func presentedFrame(at now: PredictionInstant) -> Bool {
        expire(at: now)
        let before = entries.count
        entries.removeAll { $0.standing == .confirmed }
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
            return withdrawAll(countingMisprediction: false)
        }
        guard entries[index].byte == byte else {
            return withdrawAll(countingMisprediction: true, at: now)
        }

        record(echoLatency: now - entries[index].typedAt)
        isEchoRunActive = true
        // A glyph the user never saw has nothing to hold on screen for; the
        // real character is already on its way into the grid.
        guard entries[index].isDisplayed else {
            entries.remove(at: index)
            return false
        }
        entries[index].standing = .confirmed
        entries[index].confirmedAt = now
        return true
    }

    private mutating func record(echoLatency sample: Duration) {
        guard let current = smoothedEchoLatency else {
            smoothedEchoLatency = sample
            return
        }
        smoothedEchoLatency = (current * 7 + sample) / 8
    }

    @discardableResult
    private mutating func withdrawAll(
        countingMisprediction: Bool,
        at now: PredictionInstant? = nil
    ) -> Bool {
        let wasVisible = entries.contains { $0.isDisplayed }
        if countingMisprediction, wasVisible, let now {
            recentMispredictions.append(now)
            recentMispredictions.removeAll { now - $0 > configuration.mispredictionWindow }
            if recentMispredictions.count >= configuration.mispredictionsBeforeSuspending {
                suspendedUntil = now + configuration.suspension
                recentMispredictions.removeAll()
            }
        }
        entries.removeAll()
        isEchoRunActive = false
        return wasVisible
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

        let expiredSpeculation = entries.contains {
            $0.standing == .speculative && now - $0.typedAt > configuration.speculativeLifetime
        }
        guard expiredSpeculation else { return staleConfirmation }
        // Nothing came back. Whatever we drew was wrong, or the link stalled.
        return withdrawAll(countingMisprediction: true, at: now) || staleConfirmation
    }

    private static func lonePrintableASCII(_ text: String) -> UInt8? {
        var iterator = text.utf8.makeIterator()
        guard let byte = iterator.next(), iterator.next() == nil else { return nil }
        guard (0x20...0x7E).contains(byte) else { return nil }
        return byte
    }
}
