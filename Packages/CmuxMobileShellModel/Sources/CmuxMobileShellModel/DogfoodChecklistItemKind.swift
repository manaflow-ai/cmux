public import Foundation

/// How a ``DogfoodChecklistItem`` is answered.
///
/// Encodes in the JSON wire form as a `kind` discriminator plus, for
/// ``choice``, a sibling `choices` array on the item:
///
/// ```json
/// {"id": "i1", "prompt": "Works?", "kind": "pass_fail"}
/// {"id": "i2", "prompt": "Which one?", "kind": "choice", "choices": ["a", "b"]}
/// ```
public enum DogfoodChecklistItemKind: Equatable, Sendable {
    /// A fixed pass / fail / skip segmented control.
    case passFail
    /// A custom set of mutually exclusive choices supplied by the agent.
    case choice([String])

    /// The fixed choice labels for ``passFail``, in display order. These are the
    /// raw answer values stored in a ``DogfoodFeedbackAnswer``; the pane may
    /// localize the visible label, but the stored value is one of these.
    public static let passFailChoices = ["pass", "fail", "skip"]

    /// The wire discriminator string for ``passFail``.
    static let passFailWireValue = "pass_fail"
    /// The wire discriminator string for ``choice``.
    static let choiceWireValue = "choice"
}
