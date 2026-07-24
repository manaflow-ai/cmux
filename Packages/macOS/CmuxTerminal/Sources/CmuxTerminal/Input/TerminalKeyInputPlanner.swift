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
        let committedText = snapshot.committedText.filter {
            !shouldSuppressControlText($0, composing: composing)
        }

        if snapshot.hadMarkedText, !snapshot.committedText.isEmpty {
            var actions = committedText.map(TerminalKeyInputAction.sendCommittedText)
            if snapshot.textInputCommandPerformed {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        if !snapshot.committedText.isEmpty {
            var actions: [TerminalKeyInputAction] = committedText.map {
                .sendKey(text: $0, composing: false)
            }
            if snapshot.textInputCommandPerformed {
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
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}
