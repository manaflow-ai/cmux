/// The speaker/source of one transcript turn in a session preview.
///
/// This is the pure data half: only the cases plus value-type conformances live
/// here. SwiftUI-facing accessors (label/foregroundColor/backgroundColor/bodyFont)
/// stay app-side in an extension, because they depend on localization
/// (`String(localized:)`, which must resolve against the app bundle) and SwiftUI
/// `Color`/`Font`.
public enum SessionTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case event
}
