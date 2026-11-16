public import CmuxNextDesign

/// The font picker's layouts (`palette.fontPickerStyle` in Debug Settings, DEV and NIGHTLY only):
/// the gallery's variants. Release builds use `dock`.
public nonisolated enum PaletteFontPickerStyle: String, Sendable, CaseIterable, TunableChoice {
    /// The list of families on top; under it a dock with the target strip, a sample drawn in the
    /// highlighted family at the chosen size and line height, and the size and line height sliders
    /// (default).
    case dock
    /// Each family row carries its own sample in its face; under the list one line with the target
    /// strip and both sliders side by side. The most families on screen.
    case inline
    /// The families on the left; on the right a column with the targets, the sample and the sliders
    /// stacked, like a settings inspector.
    case side

    public var tunableTitle: String {
        switch self {
        case .dock: "Dock: sample and sliders under the list (default)"
        case .inline: "Inline: a sample on every row, sliders in one line"
        case .side: "Side: targets, sample and sliders in a column"
        }
    }

    /// Rows draw a sample of the family after its name.
    public var rowsCarrySamples: Bool { self == .inline }
}
