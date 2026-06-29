#if canImport(UIKit)
import CmuxMobileTerminalKit
import Foundation
import UIKit

/// A cancellable repeating timer for hardware-key hold-to-repeat.
///
/// Abstracted behind a protocol so production drives the cadence with a real
/// `DispatchSourceTimer` (``TerminalKeyRepeatDispatchTimer``) while tests inject
/// a fake whose ticks fire synchronously — the cadence is exercised with zero
/// wall-clock waiting and no `Task.sleep`/`Clock.sleep` in the runtime path.
@MainActor
protocol TerminalKeyRepeatTimer: AnyObject {
    /// Stop the timer permanently. Safe to call more than once; a cancelled timer
    /// never ticks again.
    func cancel()
}

/// Creates ``TerminalKeyRepeatTimer`` instances for hold-to-repeat.
///
/// Injected into ``TerminalHardwareKeyCapture`` so the held-key cadence can be
/// driven by a real timer in production or a deterministic fake in tests.
@MainActor
protocol TerminalKeyRepeatTimerFactory {
    /// Make a timer that calls `onTick` once after `initialDelay`, then once
    /// every `interval`, until it is cancelled.
    ///
    /// - Parameters:
    ///   - initialDelay: The quiet "hold before repeat" delay before the first
    ///     tick. The synchronous key press already emitted the keystroke once, so
    ///     the timer stays silent for this leading delay.
    ///   - interval: The delay between ticks once repeating has begun.
    ///   - onTick: Invoked on the main actor for each tick (the first after
    ///     `initialDelay`, then every `interval`).
    /// - Returns: A live, cancellable timer.
    func makeRepeatTimer(
        initialDelay: Duration,
        interval: Duration,
        onTick: @escaping @MainActor () -> Void
    ) -> any TerminalKeyRepeatTimer
}

/// Production ``TerminalKeyRepeatTimerFactory`` backed by `DispatchSourceTimer`.
struct TerminalKeyRepeatDispatchTimerFactory: TerminalKeyRepeatTimerFactory {
    /// Creates a dispatch-timer factory.
    init() {}

    /// Makes a `DispatchSourceTimer`-backed ``TerminalKeyRepeatTimer``.
    func makeRepeatTimer(
        initialDelay: Duration,
        interval: Duration,
        onTick: @escaping @MainActor () -> Void
    ) -> any TerminalKeyRepeatTimer {
        TerminalKeyRepeatDispatchTimer(initialDelay: initialDelay, interval: interval, onTick: onTick)
    }
}

/// A ``TerminalKeyRepeatTimer`` driven by a main-queue `DispatchSourceTimer`.
///
/// A dispatch timer (not a `RunLoop` `Timer`) keeps firing through UIKit
/// tracking run-loop modes, so a held key keeps repeating even while another
/// gesture is in flight; and it carries no `Task.sleep`/`Clock.sleep`, so the
/// latency-sensitive input path holds no sleep-based runtime timing. The source
/// is scheduled on `.main`, so its handler already runs on the main actor.
@MainActor
final class TerminalKeyRepeatDispatchTimer: TerminalKeyRepeatTimer {
    /// The backing dispatch source: created and resumed in ``init(initialDelay:interval:onTick:)``
    /// and set back to `nil` by ``cancel()``, which is what makes cancellation idempotent.
    private var source: DispatchSourceTimer?

    /// Schedule and start the timer.
    /// - Parameters:
    ///   - initialDelay: Delay before the first tick.
    ///   - interval: Delay between subsequent ticks.
    ///   - onTick: Main-actor closure invoked on every tick.
    init(initialDelay: Duration, interval: Duration, onTick: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + Self.seconds(initialDelay),
            repeating: Self.seconds(interval)
        )
        source.setEventHandler {
            // The source fires on `.main`, which is the main actor's executor, so
            // hop in without an `await` — the cadence stays synchronous and the
            // held-key bytes flush immediately.
            MainActor.assumeIsolated { onTick() }
        }
        self.source = source
        source.resume()
    }

    /// Cancel the underlying dispatch source. Idempotent.
    func cancel() {
        source?.cancel()
        source = nil
    }

    /// Converts a `Duration` to whole-plus-fractional seconds for dispatch APIs.
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

/// Owns the iOS terminal's hardware-keyboard capture and hold-to-repeat,
/// extracted out of ``TerminalInputTextView`` so that 1847-line view keeps only
/// thin `pressesBegan`/`pressesEnded`/`pressesCancelled` overrides that delegate
/// here.
///
/// The direct-terminal first responder is a `UIKeyInput`/`UITextInput` proxy.
/// With UIKit's text-editing layer focused on a zero-width virtual document,
/// arrows/Tab/Ctrl-nav are consumed as no-op caret edits BEFORE `keyCommands`
/// can fire, so capture has to happen at `pressesBegan` — below the text system.
/// This type resolves each physical press to its VT bytes (via
/// ``TerminalHardwareKeyResolver``), emits them once immediately, and arms a
/// ``TerminalKeyRepeatTimer`` that re-emits the same bytes on the typematic
/// cadence until the key is released, cancelled, or focus leaves the proxy.
/// Presses it does not claim are returned to the caller to forward to `super`.
@MainActor
final class TerminalHardwareKeyCapture {
    /// Forwards encoded VT bytes to the terminal transport (the proxy's
    /// `onEscapeSequence` sink). Used for both the immediate keystroke and every
    /// held-key repeat.
    private let emit: (Data) -> Void
    /// Whether an IME composition is currently marked. Capture never claims a
    /// press while composing, so CJK/emoji input keeps routing through the text
    /// system.
    private let isComposing: () -> Bool
    /// Makes the hold-to-repeat timers; injected for deterministic tests.
    private let timerFactory: any TerminalKeyRepeatTimerFactory

    /// Presses this proxy captured (consumed AND encoded) in ``pressesBegan(_:)``,
    /// tracked so the matching ``pressesEnded(_:)`` / ``pressesCancelled(_:)`` are
    /// withheld from `super` while every press forwarded in `began` IS forwarded
    /// again — keeping UIKit's begin/end/cancel events balanced. Keying the
    /// end/cancel decision off ``shouldConsume(_:)`` instead drifts: a
    /// consumed-but-unencodable chord (e.g. Option+Up, which has no terminal
    /// encoding) is forwarded to `super` in `began` yet still reports
    /// `shouldConsume == true`, so `super` would see a `began` with no matching
    /// `ended`.
    private var capturedPresses: Set<UIPress> = []

    /// Active hold-to-repeat timers, keyed by physical key code. Independent per
    /// key so overlapping holds each repeat and releasing one key stops only its
    /// own timer. Fully `private`: tests assert repeat-timer lifecycle through
    /// the injected timer factory's fakes, never by reading this state.
    private var repeatTimers: [UIKeyboardHIDUsage: any TerminalKeyRepeatTimer] = [:]

    /// Delay before a held key starts repeating (a standard keyboard's typematic
    /// "hold before repeat" pause).
    static let keyRepeatInitialDelay: Duration = .milliseconds(400)
    /// Per-tick cadence once a held key is repeating (≈0.06s — a standard
    /// keyboard's typematic feel, close to the arrow nub's 80ms repeat).
    static let keyRepeatInterval: Duration = .milliseconds(60)

    /// Creates a capture coordinator.
    /// - Parameters:
    ///   - timerFactory: Source of hold-to-repeat timers. Defaults to the
    ///     `DispatchSourceTimer`-backed production factory; tests inject a fake.
    ///   - isComposing: Reports whether an IME composition is marked.
    ///   - emit: Sink for encoded VT bytes (immediate keystroke and repeats).
    init(
        timerFactory: any TerminalKeyRepeatTimerFactory = TerminalKeyRepeatDispatchTimerFactory(),
        isComposing: @escaping () -> Bool,
        emit: @escaping (Data) -> Void
    ) {
        self.timerFactory = timerFactory
        self.isComposing = isComposing
        self.emit = emit
    }

    // MARK: Press lifecycle (called by the proxy's thin overrides)

    /// Handle a `pressesBegan` batch: claim every press the terminal wants and
    /// return the rest for the caller to forward to `super`.
    func pressesBegan(_ presses: Set<UIPress>) -> Set<UIPress> {
        var forwarded: Set<UIPress> = []
        for press in presses {
            TerminalInputDebugLog.log(
                "proxy.pressesBegan keyCode=\(press.key?.keyCode.rawValue ?? -1) "
                    + "mods=\(press.key?.modifierFlags.rawValue ?? 0) "
                    + "handled=\(shouldConsume(press))"
            )
            if handleHardwarePress(press) {
                capturedPresses.insert(press)
            } else {
                forwarded.insert(press)
            }
        }
        return forwarded
    }

    /// Handle a `pressesEnded` batch: stop each released key's repeat and return
    /// the presses whose `began` was forwarded (so begin/end stay balanced).
    func pressesEnded(_ presses: Set<UIPress>) -> Set<UIPress> {
        endOrCancel(presses)
    }

    /// Handle a `pressesCancelled` batch identically to `pressesEnded` — a
    /// preempted press must cancel its repeat just like a normal release.
    func pressesCancelled(_ presses: Set<UIPress>) -> Set<UIPress> {
        endOrCancel(presses)
    }

    /// Cancel every in-flight repeat and drop captured presses (focus loss /
    /// teardown). A key held while focus leaves the proxy never delivers its
    /// `pressesEnded`, so its repeat must be cancelled here to avoid a runaway
    /// timer, and its captured `UIPress` dropped (the matching end never arrives).
    func reset() {
        stopAllKeyRepeats()
        capturedPresses.removeAll()
    }

    /// Shared `pressesEnded`/`pressesCancelled` body: stop each key's repeat and
    /// return the un-captured presses for the caller to forward to `super`.
    private func endOrCancel(_ presses: Set<UIPress>) -> Set<UIPress> {
        var forwarded: Set<UIPress> = []
        for press in presses {
            // Releasing a key stops only its own repeat, regardless of whether it
            // is still "consumed", so an overlapping hold of another key keeps
            // repeating.
            if let keyCode = press.key?.keyCode { stopKeyRepeat(for: keyCode) }
            // Forward to `super` exactly the presses whose `began` we forwarded
            // (the ones we did NOT capture), so begin/end stay balanced.
            if capturedPresses.remove(press) == nil { forwarded.insert(press) }
        }
        return forwarded
    }

    // MARK: Capture decision + encode

    /// Whether this press should be captured for the terminal instead of the
    /// focused text system. Special navigation/control keys (arrows, Home/End,
    /// Page Up/Down, forward-Delete, Escape, Tab) and any Control/Option chord
    /// are claimed; plain characters fall through so `insertText` (and the IME)
    /// keep working. Never claim while an IME composition is marked.
    private func shouldConsume(_ press: UIPress) -> Bool {
        guard !isComposing(), let key = press.key else { return false }
        let mods = key.modifierFlags
        let isSpecial = Self.isSpecialKey(key.keyCode)
        return isSpecial || mods.contains(.control) || mods.contains(.alternate)
    }

    /// Encode a claimed press, emit its bytes once, and arm hold-to-repeat.
    /// Returns `true` when the press was claimed (so the caller withholds it from
    /// `super`) — both when it encoded to bytes (emit + repeat) and when it is a
    /// claimed chord with no terminal encoding such as Option+Up: `shouldConsume`
    /// already matched it, so it is consumed silently rather than leaked to the
    /// system's default handling. Returns `false` only when the press is genuinely
    /// unclaimed (so the caller forwards it to `super`).
    @discardableResult
    private func handleHardwarePress(_ press: UIPress) -> Bool {
        guard shouldConsume(press), let key = press.key, let input = Self.terminalInput(for: key)
        else { return false }
        let mods = key.modifierFlags
        guard let data = TerminalHardwareKeyResolver.data(input: input, modifierFlags: mods), !data.isEmpty
        else {
            // Claimed (shouldConsume matched) but the resolver produced no bytes —
            // e.g. Option+Up/Down. Consume it silently: returning `false` here would
            // forward the press to `super`, leaking the chord to the system.
            TerminalInputDebugLog.log("proxy.encode mods=\(mods.rawValue) bytes=0 (no-data)")
            return true
        }
        TerminalInputDebugLog.log("proxy.encode mods=\(mods.rawValue) \(TerminalInputDebugLog.dataSummary(data))")
        // First keystroke goes out immediately; the timer adds the held cadence.
        emit(data)
        startKeyRepeat(for: key.keyCode, bytes: data)
        return true
    }

    /// Maps a key to the `UIKeyCommand.input*` string (or the typed character)
    /// the resolver encodes. Special keys return their navigation constant; every
    /// other key returns its unmodified character so a Control/Option chord (e.g.
    /// Ctrl-C) resolves through ``TerminalHardwareKeyResolver``.
    private static func terminalInput(for key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardUpArrow: return UIKeyCommand.inputUpArrow
        case .keyboardDownArrow: return UIKeyCommand.inputDownArrow
        case .keyboardLeftArrow: return UIKeyCommand.inputLeftArrow
        case .keyboardRightArrow: return UIKeyCommand.inputRightArrow
        case .keyboardHome: return UIKeyCommand.inputHome
        case .keyboardEnd: return UIKeyCommand.inputEnd
        case .keyboardPageUp: return UIKeyCommand.inputPageUp
        case .keyboardPageDown: return UIKeyCommand.inputPageDown
        case .keyboardDeleteForward: return UIKeyCommand.inputDelete
        case .keyboardEscape: return UIKeyCommand.inputEscape
        case .keyboardTab: return "\t"
        default:
            // Resolve letter keys from the PHYSICAL keyCode, not
            // `charactersIgnoringModifiers`. On-device a Control chord can arrive
            // already pre-encoded as its C0 byte — Ctrl+C reports U+0003 (ETX),
            // not "c". That pre-encoded scalar then fails the encoder's
            // `0x40...0x5F` control-letter guard, the resolver returns nil, and
            // the keystroke is silently dropped. The keyCode is modifier- and
            // layout-independent, so it always yields the bare letter the encoder
            // needs. (Ctrl+W/U/A/E only ever worked because the device happened to
            // report their letter; this makes EVERY Control/Alt+letter chord
            // robust.) Mirrors the Mac surface's `keycodeForLetter`. Plain typing
            // is unaffected — `shouldConsume` only routes here for special keys or
            // Control/Alt chords, never a bare letter.
            if let letter = Self.letter(forKeyCode: key.keyCode) { return letter }
            return key.charactersIgnoringModifiers
        }
    }

    /// The bare lowercase letter for a US-layout letter keyCode
    /// (`.keyboardA`…`.keyboardZ` → `"a"`…`"z"`), or `nil` for any non-letter key.
    /// `keyCode` is the physical key, independent of modifiers/layout shifting, so
    /// a Control/Option chord resolves to the un-encoded letter the encoder
    /// expects even when `charactersIgnoringModifiers` has been collapsed to a C0
    /// control byte. Mirrors the Mac surface's `keycodeForLetter` (inverted:
    /// code→letter here, letter→code there).
    private static func letter(forKeyCode keyCode: UIKeyboardHIDUsage) -> String? {
        switch keyCode {
        case .keyboardA: return "a"
        case .keyboardB: return "b"
        case .keyboardC: return "c"
        case .keyboardD: return "d"
        case .keyboardE: return "e"
        case .keyboardF: return "f"
        case .keyboardG: return "g"
        case .keyboardH: return "h"
        case .keyboardI: return "i"
        case .keyboardJ: return "j"
        case .keyboardK: return "k"
        case .keyboardL: return "l"
        case .keyboardM: return "m"
        case .keyboardN: return "n"
        case .keyboardO: return "o"
        case .keyboardP: return "p"
        case .keyboardQ: return "q"
        case .keyboardR: return "r"
        case .keyboardS: return "s"
        case .keyboardT: return "t"
        case .keyboardU: return "u"
        case .keyboardV: return "v"
        case .keyboardW: return "w"
        case .keyboardX: return "x"
        case .keyboardY: return "y"
        case .keyboardZ: return "z"
        default: return nil
        }
    }

    /// The set of keyCodes whose terminal encoding is a navigation/control
    /// sequence rather than a literal character. Kept in sync with the explicit
    /// cases in ``terminalInput(for:)``. Used instead of comparing the resolved
    /// input against `charactersIgnoringModifiers`, because arrows report the same
    /// U+F70x constant for both (and Tab reports `\t` for both), so that compare
    /// would never flag the very keys this capture path exists to claim.
    private static func isSpecialKey(_ keyCode: UIKeyboardHIDUsage) -> Bool {
        switch keyCode {
        case .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
             .keyboardHome, .keyboardEnd, .keyboardPageUp, .keyboardPageDown,
             .keyboardDeleteForward, .keyboardEscape, .keyboardTab:
            return true
        default:
            return false
        }
    }

    // MARK: Hold-to-repeat (timer-driven)

    /// Arm (or re-arm) hold-to-repeat for a consumed hardware key. The first
    /// keystroke was already emitted by ``handleHardwarePress(_:)``; this only
    /// adds the held cadence via a ``TerminalKeyRepeatTimer`` that stays silent
    /// for ``keyRepeatInitialDelay``, then re-emits `bytes` every
    /// ``keyRepeatInterval`` until the key is released (``stopKeyRepeat(for:)``)
    /// or focus leaves (``reset()``) cancels it. The tick closure captures `self`
    /// weakly so a stray timer can never outlive — or retain — this coordinator.
    private func startKeyRepeat(for keyCode: UIKeyboardHIDUsage, bytes: Data) {
        repeatTimers[keyCode]?.cancel()
        repeatTimers[keyCode] = timerFactory.makeRepeatTimer(
            initialDelay: Self.keyRepeatInitialDelay,
            interval: Self.keyRepeatInterval,
            onTick: { [weak self] in
                guard let self else { return }
                self.emit(bytes)
                TerminalInputDebugLog.log(
                    "proxy.keyRepeat code=\(keyCode.rawValue) \(TerminalInputDebugLog.dataSummary(bytes))"
                )
            }
        )
    }

    /// Stop and clear the repeat timer for one key code (its key was released).
    private func stopKeyRepeat(for keyCode: UIKeyboardHIDUsage) {
        repeatTimers[keyCode]?.cancel()
        repeatTimers[keyCode] = nil
    }

    /// Cancel every in-flight repeat timer.
    private func stopAllKeyRepeats() {
        for timer in repeatTimers.values { timer.cancel() }
        repeatTimers.removeAll()
    }
}
#endif
