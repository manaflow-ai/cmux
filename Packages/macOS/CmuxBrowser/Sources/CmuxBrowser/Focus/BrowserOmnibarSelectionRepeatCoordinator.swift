public import Foundation
import Observation

/// Drives the auto-repeat of a browser omnibar selection move while the user
/// holds a Control-navigation key (for example Ctrl+arrow) with the address bar
/// focused.
///
/// The coordinator owns the small state machine that the cmux app delegate used
/// to inline: arm a repeat for a `(panel, keyCode, delta)` identity, fire the
/// first synthetic move after a 250 ms hold delay, then tick every 55 ms until
/// the key is released, the modifiers change, or focus is cleared. It does no
/// AppKit work itself; every outside-world effect is a constructor-injected
/// seam:
///
/// - ``selectionMove`` posts the per-tick selection move (the app forwards it to
///   `NotificationCenter` under `.browserMoveOmnibarSelection`).
/// - ``sleep`` is the timing source. The default is `ContinuousClock`; tests
///   inject a deterministic clock. This replaces the previous
///   `DispatchQueue.main.asyncAfter` work items, which were not cancellable in a
///   structured way and were untestable.
/// - ``debugLog`` mirrors the original `#if DEBUG` trace lines verbatim so the
///   debug-event log is byte-identical to the pre-extraction behavior.
///
/// All state is `@MainActor`-isolated, matching the app delegate that owns the
/// single instance.
@MainActor
@Observable
public final class BrowserOmnibarSelectionRepeatCoordinator {
    /// Sink invoked once per repeat tick to dispatch a selection move for a
    /// panel by a signed delta.
    public typealias SelectionMove = @MainActor (_ panelID: UUID, _ delta: Int) -> Void

    /// Sink invoked with each debug-trace line (active only when the host passes
    /// a logger; production passes `nil`).
    public typealias DebugLog = @MainActor (_ line: String) -> Void

    /// Suspends for `duration` and is cancelled when the owning repeat task is
    /// cancelled, giving the same hold-then-tick cadence the work items had.
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    /// Hold delay before the first repeat tick fires (matches the original
    /// 0.25 s `asyncAfter` deadline).
    public static let startDelay: Duration = .milliseconds(250)

    /// Interval between repeat ticks once repeating (matches the original
    /// 0.055 s `asyncAfter` deadline).
    public static let tickInterval: Duration = .milliseconds(55)

    private let selectionMove: SelectionMove
    private let sleep: Sleep
    private let debugLog: DebugLog?

    private var repeatKey: BrowserOmnibarRepeatKey?
    private var repeatTask: Task<Void, Never>?

    /// Creates a repeat coordinator with its effect seams injected.
    /// - Parameters:
    ///   - selectionMove: Dispatches a selection move for a panel by a delta.
    ///   - sleep: Cancellable timing source; defaults to `ContinuousClock`.
    ///   - debugLog: Optional trace sink; pass `nil` outside debug builds.
    public init(
        selectionMove: @escaping SelectionMove,
        sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) },
        debugLog: DebugLog? = nil
    ) {
        self.selectionMove = selectionMove
        self.sleep = sleep
        self.debugLog = debugLog
    }

    /// Identifier of the panel whose omnibar selection is currently repeating,
    /// or `nil` when no repeat is armed.
    public var repeatingPanelID: UUID? { repeatKey?.panelID }

    /// `keyCode` of the held key driving the active repeat, or `nil` when no
    /// repeat is armed.
    public var repeatingKeyCode: UInt16? { repeatKey?.keyCode }

    /// Dispatches a single selection move immediately, outside the repeat
    /// cadence. A zero delta is a no-op.
    /// - Parameters:
    ///   - panelID: Panel whose omnibar selection should move.
    ///   - delta: Signed selection-move delta.
    public func dispatchSelectionMove(panelID: UUID, delta: Int) {
        guard delta != 0 else { return }
        debugLog?(
            "browser.focus.omnibar.selectionMove panel=\(panelID.uuidString.prefix(5)) " +
            "delta=\(delta) repeatKey=\(repeatKey?.keyCode.description ?? "nil")"
        )
        selectionMove(panelID, delta)
    }

    /// Arms an auto-repeat for the given panel/key/delta if one is not already
    /// running for the same identity. A zero delta is a no-op. Re-arming with a
    /// different identity cancels the prior repeat first.
    /// - Parameters:
    ///   - panelID: Panel whose omnibar selection should repeat.
    ///   - keyCode: `keyCode` of the held key.
    ///   - delta: Signed selection-move delta per tick.
    public func startRepeatIfNeeded(panelID: UUID, keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }

        let incoming = BrowserOmnibarRepeatKey(panelID: panelID, keyCode: keyCode, delta: delta)
        if repeatKey == incoming {
            debugLog?(
                "browser.focus.omnibar.repeat.start panel=\(panelID.uuidString.prefix(5)) " +
                "key=\(keyCode) delta=\(delta) result=reuse"
            )
            return
        }

        stopRepeat()
        repeatKey = incoming
        debugLog?(
            "browser.focus.omnibar.repeat.start panel=\(panelID.uuidString.prefix(5)) " +
            "key=\(keyCode) delta=\(delta) result=armed"
        )

        repeatTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleep(Self.startDelay)
            } catch {
                return
            }
            await self.runRepeatLoop()
        }
    }

    /// Cancels any in-flight repeat and clears the armed identity, emitting the
    /// stop trace line when a repeat was active.
    public func stopRepeat() {
        let previous = repeatKey
        repeatTask?.cancel()
        repeatTask = nil
        repeatKey = nil
        if let previous, previous.keyCode != 0 || previous.delta != 0 {
            debugLog?(
                "browser.focus.omnibar.repeat.stop panel=\(previous.panelID.uuidString.prefix(5)) " +
                "key=\(previous.keyCode) " +
                "delta=\(previous.delta)"
            )
        }
    }

    /// Stops the repeat when the released key matches the held key.
    /// - Parameter keyCode: `keyCode` of the key-up event.
    public func noteKeyUp(keyCode: UInt16) {
        guard repeatKey != nil else { return }
        if keyCode == repeatKey?.keyCode {
            debugLog?(
                "browser.focus.omnibar.repeat.lifecycle event=keyUp key=\(keyCode) " +
                "action=stop"
            )
            stopRepeat()
        }
    }

    /// Stops the repeat when a modifier change no longer satisfies the
    /// Control-navigation hold.
    /// - Parameters:
    ///   - shouldContinue: Whether the new modifier state still drives a repeat.
    ///   - flagsRawValue: Raw modifier value for the trace line.
    public func noteFlagsChanged(shouldContinue: Bool, flagsRawValue: UInt) {
        guard repeatKey != nil else { return }
        if !shouldContinue {
            debugLog?(
                "browser.focus.omnibar.repeat.lifecycle event=flagsChanged " +
                "flags=\(flagsRawValue) action=stop"
            )
            stopRepeat()
        }
    }

    private func runRepeatLoop() async {
        while !Task.isCancelled {
            guard let key = repeatKey else {
                debugLog?("browser.focus.omnibar.repeat.tick result=stop_no_focused_address_bar")
                stopRepeat()
                return
            }

            debugLog?(
                "browser.focus.omnibar.repeat.tick panel=\(key.panelID.uuidString.prefix(5)) " +
                "delta=\(key.delta)"
            )
            dispatchSelectionMove(panelID: key.panelID, delta: key.delta)

            do {
                try await sleep(Self.tickInterval)
            } catch {
                return
            }
        }
    }
}
