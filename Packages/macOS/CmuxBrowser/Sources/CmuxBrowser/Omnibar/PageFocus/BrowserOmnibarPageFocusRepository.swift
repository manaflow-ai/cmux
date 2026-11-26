import Foundation

/// Owns the address-bar page-focus capture/restore subsystem for one browser panel.
///
/// When the omnibar takes keyboard focus the page's editable element loses first
/// responder, and when the omnibar closes that page element must regain focus
/// with its prior text selection intact. This repository captures the active
/// editable element's id and selection into a page-side global via the capture
/// script, and later re-focuses it via the restore script, retrying on a fixed
/// delay schedule because WebKit may not have re-rendered the element yet.
///
/// All WebKit access is routed through an injected ``BrowserOmnibarScriptEvaluating``
/// seam so the type has no WebKit or `BrowserPanel` dependency. A monotonically
/// increasing generation counter invalidates in-flight restore attempts the
/// moment focus intent changes again, so a stale retry never steals focus back.
///
/// Behavior here is a byte-identical lift of the former `BrowserPanel` methods:
/// the same scripts, the same `[0.0, 0.03, 0.09, 0.2]` retry delays, the same
/// generation guards, and the same main-queue scheduling.
@MainActor
public final class BrowserOmnibarPageFocusRepository {
    private let evaluator: any BrowserOmnibarScriptEvaluating
    private let logSink: (@MainActor @Sendable (String) -> Void)?
    private var restoreGeneration: UInt64 = 0

    /// The fixed retry delay schedule (seconds) for restore attempts.
    ///
    /// The first attempt is immediate; subsequent attempts back off so that a
    /// page mid-render eventually accepts focus without a tight busy loop.
    private static let restoreDelays: [TimeInterval] = [0.0, 0.03, 0.09, 0.2]

    /// Creates a repository bound to one panel's page-focus seam.
    ///
    /// - Parameters:
    ///   - evaluator: The script evaluator that runs JavaScript in the panel's
    ///     live page. Held strongly; the conformer is expected to hold its own
    ///     owner weakly to avoid a retain cycle.
    ///   - logSink: Optional debug-log sink invoked on the main actor with the
    ///     same messages the panel previously emitted. Pass `nil` in release.
    public init(
        evaluator: any BrowserOmnibarScriptEvaluating,
        logSink: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        self.evaluator = evaluator
        self.logSink = logSink
    }

    /// Captures the page's currently focused editable element if one is editable.
    ///
    /// Stores `{ id, selectionStart, selectionEnd }` into a page-side global so a
    /// later ``restoreIfNeeded(panelDebugID:completion:)`` can re-focus exactly
    /// that element. A no-op when nothing editable is focused.
    ///
    /// - Parameter panelDebugID: Short panel id used only for debug logging.
    public func captureIfNeeded(panelDebugID: String) {
        evaluator.evaluateOmnibarPageFocusScript(Self.captureScript) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.log(
                    "browser.focus.addressBar.capture panel=\(panelDebugID) " +
                    "result=error message=\(error.localizedDescription)"
                )
                return
            }
            let resultValue = (result as? String) ?? "unknown"
            self.log(
                "browser.focus.addressBar.capture panel=\(panelDebugID) " +
                "result=\(resultValue)"
            )
        }
    }

    /// Cancels any in-flight restore attempts by bumping the generation.
    ///
    /// Call before re-entering the omnibar or whenever focus intent changes, so a
    /// previously scheduled retry resolves as stale and stops re-focusing the page.
    ///
    /// - Parameter panelDebugID: Short panel id used only for debug logging.
    public func invalidateRestoreAttempts(panelDebugID: String) {
        restoreGeneration &+= 1
        log(
            "browser.focus.addressBar.restore.invalidate panel=\(panelDebugID) " +
            "generation=\(restoreGeneration)"
        )
    }

    /// Attempts to restore page input focus to the previously captured element.
    ///
    /// Bumps the generation, then runs the restore script on the fixed delay
    /// schedule, retrying only on `notFocused`/`error` and only while the
    /// generation is still current. Completes with `true` once the element is
    /// re-focused and its selection restored, otherwise `false`.
    ///
    /// - Parameters:
    ///   - panelDebugID: Short panel id used only for debug logging.
    ///   - completion: Invoked once on the main actor with the restore outcome.
    public func restoreIfNeeded(
        panelDebugID: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        restoreGeneration &+= 1
        let generation = restoreGeneration
        restoreAttempt(
            attempt: 0,
            generation: generation,
            panelDebugID: panelDebugID,
            completion: completion
        )
    }

    private func restoreAttempt(
        attempt: Int,
        generation: UInt64,
        panelDebugID: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard generation == restoreGeneration else {
            completion(false)
            return
        }
        evaluator.evaluateOmnibarPageFocusScript(Self.restoreScript) { [weak self] result, error in
            guard let self else {
                completion(false)
                return
            }
            guard generation == self.restoreGeneration else {
                completion(false)
                return
            }

            let status = AddressBarPageFocusRestoreStatus.from(result: result, error: error)
            let canRetry = (status == .notFocused || status == .error)
            let hasNextAttempt = attempt + 1 < Self.restoreDelays.count

            if let error {
                self.log(
                    "browser.focus.addressBar.restore panel=\(panelDebugID) " +
                    "attempt=\(attempt) status=\(status.rawValue) " +
                    "message=\(error.localizedDescription)"
                )
            } else {
                self.log(
                    "browser.focus.addressBar.restore panel=\(panelDebugID) " +
                    "attempt=\(attempt) status=\(status.rawValue)"
                )
            }

            if status == .restored {
                completion(true)
                return
            }

            if canRetry && hasNextAttempt {
                let delay = Self.restoreDelays[attempt + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else {
                        completion(false)
                        return
                    }
                    guard generation == self.restoreGeneration else {
                        completion(false)
                        return
                    }
                    self.restoreAttempt(
                        attempt: attempt + 1,
                        generation: generation,
                        panelDebugID: panelDebugID,
                        completion: completion
                    )
                }
                return
            }

            completion(false)
        }
    }

    private func log(_ message: String) {
        logSink?(message)
    }
}
