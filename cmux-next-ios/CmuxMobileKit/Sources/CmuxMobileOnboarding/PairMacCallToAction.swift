/// The "Connect your Mac" step's one call to action (D6, terminal QA round 10).
///
/// The step used to swap two buttons, `PrimaryCapsule("Continue")` and
/// `TextCTA("Not now")`, when the active space's online Mac appeared. That flip
/// lands when the team's Mac list answers, which on a loaded phone is seconds
/// after the page opens, right when the user taps: the finger stayed on a
/// button that had been removed, and the tap was lost. Now there is one button
/// with one identity; only its label and emphasis follow the state, so a press
/// survives the flip.
///
/// Mid-press flip: the action is resolved at touch-up, from the state then
/// (the button reads `action` when it fires). Both states advance, so a tap
/// that starts on "Not now" and ends on "Continue", or the reverse, advances
/// to the next step either way.
public struct PairMacCallToAction: Equatable, Sendable, Identifiable {
    public enum Emphasis: Equatable, Sendable {
        /// The accent capsule: a Mac is online.
        case primary
        /// Plain text: still waiting for a Mac.
        case text
    }

    public enum Action: Equatable, Sendable {
        /// Go to the next setup step (or finish setup).
        case advance
    }

    /// The button's identity and accessibility identifier, the same in every state.
    public static let accessibilityIdentifier = "setup.pair-mac.cta"

    public let title: String
    public let emphasis: Emphasis

    public init(macOnline: Bool) {
        title = macOnline ? "Continue" : "Not now"
        emphasis = macOnline ? .primary : .text
    }

    public var id: String { Self.accessibilityIdentifier }

    /// What a tap does, read when the tap lands (touch-up).
    public var action: Action { .advance }
}
