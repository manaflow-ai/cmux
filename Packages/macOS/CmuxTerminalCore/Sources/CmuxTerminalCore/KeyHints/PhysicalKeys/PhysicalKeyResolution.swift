/// Which physical keys to press for a chord an agent expects.
public enum PhysicalKeyResolution: Sendable, Equatable {
    /// Press the chord as the agent printed it, or cmux can't tell better.
    case asPrinted
    /// Press these physical keys instead.
    case press(PhysicalKeyPress)
}

/// Physical keys that produce an agent's chord, and why they differ from
/// the printed ones.
public struct PhysicalKeyPress: Sendable, Hashable {
    /// The keys to press.
    public var chord: PhysicalKeyChord
    /// Keys in the chord that send another key on their own, such as Caps
    /// Lock sending Control.
    public var notes: [PhysicalKeyNote]
    /// Whether a Karabiner-Elements complex modification turns the chord
    /// into the agent's chord.
    public var viaKarabinerRule: Bool

    public init(chord: PhysicalKeyChord, notes: [PhysicalKeyNote], viaKarabinerRule: Bool) {
        self.chord = chord
        self.notes = notes
        self.viaKarabinerRule = viaKarabinerRule
    }
}

/// A physical key that sends a different key: "Caps Lock is your Control key".
public struct PhysicalKeyNote: Sendable, Hashable {
    /// The key the user presses.
    public var physical: PhysicalKey
    /// The key macOS delivers for it.
    public var sends: PhysicalKey

    public init(physical: PhysicalKey, sends: PhysicalKey) {
        self.physical = physical
        self.sends = sends
    }
}
