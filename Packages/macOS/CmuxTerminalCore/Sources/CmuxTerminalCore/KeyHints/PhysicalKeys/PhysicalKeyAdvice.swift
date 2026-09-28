/// Physical keys to press for a hint's keys on some of the user's
/// keyboards, when they differ from the printed keys.
public struct PhysicalKeyAdvice: Sendable, Equatable {
    /// Names of the keyboards this applies to.
    public var keyboardNames: [String]
    /// Whether this applies to every connected keyboard, so the names
    /// needn't be shown.
    public var appliesToEveryKeyboard: Bool
    /// The chords to press, one for each of the hint's keys.
    public var chords: [PhysicalKeyChord]
    /// Keys in the chords that send another key on their own.
    public var notes: [PhysicalKeyNote]
    /// Whether a Karabiner-Elements complex modification is involved.
    public var viaKarabinerRule: Bool

    public init(
        keyboardNames: [String],
        appliesToEveryKeyboard: Bool,
        chords: [PhysicalKeyChord],
        notes: [PhysicalKeyNote],
        viaKarabinerRule: Bool
    ) {
        self.keyboardNames = keyboardNames
        self.appliesToEveryKeyboard = appliesToEveryKeyboard
        self.chords = chords
        self.notes = notes
        self.viaKarabinerRule = viaKarabinerRule
    }
}
