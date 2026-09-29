public import CmuxNextDesign

// Localized names for the shared group colors (swatch accessibility labels).
extension GroupColor {
    public var localizedName: String {
        switch self {
        case .grey: Strings.colorGrey
        case .blue: Strings.colorBlue
        case .red: Strings.colorRed
        case .yellow: Strings.colorYellow
        case .green: Strings.colorGreen
        case .pink: Strings.colorPink
        case .purple: Strings.colorPurple
        case .cyan: Strings.colorCyan
        case .orange: Strings.colorOrange
        }
    }
}
