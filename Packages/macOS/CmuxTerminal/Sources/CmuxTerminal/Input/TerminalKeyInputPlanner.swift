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
    public func actions(for snapshot: TerminalKeyInputSnapshot) -> [TerminalKeyInputAction] {
        guard !snapshot.inputSourceChanged else { return [] }

        let composing = snapshot.hadMarkedText || snapshot.hasMarkedText
        let committedText = snapshot.committedText.filter {
            !shouldSuppressControlText($0, composing: composing)
        }

        if snapshot.hadMarkedText, !snapshot.committedText.isEmpty {
            var actions = committedText.map(TerminalKeyInputAction.sendCommittedText)
            if shouldReplayCommittedPreeditKey(snapshot.event) {
                actions.append(.sendKey(text: nil, composing: false))
            }
            return actions
        }

        if !snapshot.committedText.isEmpty {
            return committedText.map {
                .sendKey(text: $0, composing: false)
            }
        }

        guard !shouldSuppressControlText(
            snapshot.event.rawText,
            composing: composing
        ) else {
            return []
        }

        return [
            .sendKey(
                text: snapshot.event.translatedText,
                composing: composing
            ),
        ]
    }

    private func shouldReplayCommittedPreeditKey(_ event: TerminalKeyInputEvent) -> Bool {
        switch event.key {
        case .arrowDown, .arrowRight, .arrowUp:
            return true
        case .arrowLeft:
            return event.hasModifier
        case .other:
            return false
        }
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
