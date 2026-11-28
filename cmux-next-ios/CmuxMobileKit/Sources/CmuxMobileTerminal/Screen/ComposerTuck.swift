import Foundation

/// What tucks away while the composer is in use (Leo, 2026-11-23: "better ways/heuristics of
/// auto-tucking swathes of the coding harness tui and the weird little action buttons above the
/// composer is a worthwhile endeavour too").
///
/// The composer is in use while it has focus, or holds a draft while the terminal does not have
/// focus. Then the key row above it, and the rows of a coding harness's screen that only repeat
/// status (its own input box, footer hints, live spinner; the Rust rule `harness_tuck` reads
/// them), give their room to the conversation. They come back when the composer is put away,
/// when the terminal takes focus (the person asks for the keys by tapping it), and whenever the
/// harness asks a question the person must answer. Three variants, for the gallery
/// (`-cmuxMobileComposerTuck keys|chrome|both`); `both` ships.
public enum ComposerTuck: String, CaseIterable, Sendable {
    /// Only the key row tucks; the harness's rows stay.
    case keys
    /// Only the harness's status rows tuck; the key row stays over the keyboard.
    case chrome
    /// Both (the default).
    case both

    public var tucksKeys: Bool { self != .chrome }
    public var tucksChrome: Bool { self != .keys }

    public var title: String {
        switch self {
        case .keys: "Keys tuck"
        case .chrome: "Harness rows tuck"
        case .both: "Keys and harness rows tuck"
        }
    }

    /// The variant in effect: `both`, unless a launch argument or default names another.
    public static var current: ComposerTuck {
        UserDefaults.standard.string(forKey: "cmuxMobileComposerTuck").flatMap(ComposerTuck.init(rawValue:)) ?? .both
    }
}
