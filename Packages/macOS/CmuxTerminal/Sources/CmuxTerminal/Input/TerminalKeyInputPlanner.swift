/// Converts AppKit text transitions into deterministic libghostty input actions.
///
/// The planner is locale-independent. AppKit owns text composition and libghostty
/// owns modifier translation; this type only reconciles the resulting state change.
public struct TerminalKeyInputPlanner: Sendable {
    /// Creates a terminal key input planner.
    public init() {}

    /// Plans the libghostty operations for one interpreted native key.
    ///
    /// - Parameter snapshot: State captured around AppKit interpretation.
    /// - Returns: Ordered terminal input actions, or an empty array when AppKit
    ///   consumed the key entirely.
    public func plan(for snapshot: TerminalKeyInputSnapshot) -> TerminalKeyInputPlan {
        TerminalKeyInputPlan(actions: plannedActions(for: snapshot))
    }

    /// Returns only the ordered terminal operations for callers that do not
    /// manage native key-up ownership.
    public func actions(for snapshot: TerminalKeyInputSnapshot) -> [TerminalKeyInputAction] {
        plan(for: snapshot).actions
    }

    private func plannedActions(for snapshot: TerminalKeyInputSnapshot) -> [TerminalKeyInputAction] {
        let composing = snapshot.hadMarkedText || snapshot.hasMarkedText
        let normalizedCommittedText = normalizedCommittedText(
            for: snapshot,
            composing: composing
        )
        let committedText = normalizedCommittedText.filter {
            !shouldSuppressControlText($0, composing: composing)
        }
        let suppressedAccumulatedControl = normalizedCommittedText.contains {
            shouldSuppressControlText($0, composing: composing)
        }

        if snapshot.hadMarkedText, !snapshot.committedText.isEmpty {
            var actions = committedText.map(TerminalKeyInputAction.sendCommittedText)
            let physicalKeyDuplicatesCommittedText =
                commandCallbackDuplicatesCommittedText(
                    committedText,
                    translatedText: snapshot.event.translatedText
                )
            let replaysDistinctCommand =
                snapshot.textInputCommandPerformed &&
                !suppressedAccumulatedControl &&
                !physicalKeyDuplicatesCommittedText
            let replaysUnconsumedPhysicalKey =
                !snapshot.textInputConsumed &&
                !physicalKeyDuplicatesCommittedText
            let replaysLiteralCommitKey =
                snapshot.committedTextMatchesPreedit &&
                snapshot.event
                    .replaysPhysicalKeyAfterLiteralPreeditCommit
            let replaysPhysicalKey =
                replaysUnconsumedPhysicalKey ||
                snapshot.event.replaysPhysicalKeyAfterPreeditCommit ||
                replaysLiteralCommitKey ||
                replaysDistinctCommand
            if replaysPhysicalKey {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        if !snapshot.committedText.isEmpty {
            var actions: [TerminalKeyInputAction] = committedText.map {
                .sendCommittedKey($0)
            }
            if !suppressedAccumulatedControl,
               snapshot.textInputCommandPerformed,
               !commandCallbackDuplicatesCommittedText(
                   committedText,
                   translatedText: snapshot.event.translatedText
               ) {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        guard !shouldSuppressControlText(
            snapshot.event.rawText,
            composing: composing
        ) else {
            return []
        }

        if snapshot.textInputCommandPerformed {
            return [
                .sendKey(
                    text: forwardableCommandText(
                        snapshot.event.translatedText
                    ),
                    composing: false
                ),
            ]
        }

        if snapshot.textInputConsumed,
           snapshot.preeditCaretMoved,
           snapshot.event.replaysPhysicalKeyAfterPreeditCaretMove {
            return [.sendKey(text: nil, composing: false)]
        }

        if snapshot.textInputConsumed {
            return []
        }

        return [
            .sendKey(
                text: snapshot.event.translatedText,
                composing: composing
            ),
        ]
    }

    private func shouldSuppressControlText(_ text: String?, composing: Bool) -> Bool {
        composing && TerminalTextInputText.isSingleC0(text)
    }

    /// AppKit can surface the event's raw C0/DEL payload through `insertText`
    /// even when layout translation recovered printable text for that same
    /// physical event. The raw control is not committed terminal text. Replace
    /// it only when all semantic signals agree, leaving composition and genuine
    /// control input on their existing physical-key paths.
    private func normalizedCommittedText(
        for snapshot: TerminalKeyInputSnapshot,
        composing: Bool
    ) -> [String] {
        guard !composing,
              snapshot.committedText.count == 1,
              let rawText = snapshot.event.rawText,
              snapshot.committedText[0] == rawText,
              TerminalTextInputText.isSingleC0OrDelete(rawText),
              let recoveredText = forwardableCommandText(
                  snapshot.event.translatedText
              ) else {
            return snapshot.committedText
        }
        return [recoveredText]
    }

    /// `interpretKeyEvents` may report the same physical key through both
    /// `insertText` and `doCommand`. Once the committed text exactly matches
    /// the event's translated printable text, replaying the command would send
    /// the key twice. A distinct command still follows the commit so input
    /// methods can commit preedit text and then delegate navigation.
    private func commandCallbackDuplicatesCommittedText(
        _ committedText: [String],
        translatedText: String?
    ) -> Bool {
        guard let translatedText = forwardableCommandText(translatedText) else {
            return false
        }
        return committedText.joined() == translatedText
    }

    /// AppKit can delegate a physical key through `doCommand` even when the
    /// layout resolver recovered printable text for it. Preserve that opaque
    /// text while keeping native control keys textless for Ghostty's encoder.
    private func forwardableCommandText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return TerminalTextInputText.isSingleC0OrDelete(text) ? nil : text
    }
}
