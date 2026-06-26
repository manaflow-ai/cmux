/// The tint applied to the browser panel's DevTools button.
///
/// Persisted by raw value under
/// ``BrowserDevToolsButtonDebugSettings/iconColorKey``. ``title`` is the
/// human-readable label shown in the debug picker. The resolved SwiftUI `Color`
/// is computed app-side (the `.accent` case binds to the live app accent), so it
/// is not part of this value type.
public enum BrowserDevToolsIconColorOption: String, CaseIterable, Identifiable, Sendable {
    case bonsplitInactive
    case bonsplitActive
    case accent
    case tertiary

    /// The stable identity used for `Identifiable`, equal to the raw value.
    public var id: String { rawValue }

    /// The human-readable label shown in the DevTools color picker.
    public var title: String {
        switch self {
        case .bonsplitInactive: return "Bonsplit Inactive (Terminal/Globe)"
        case .bonsplitActive: return "Bonsplit Active (Terminal/Globe)"
        case .accent: return "Accent"
        case .tertiary: return "Tertiary"
        }
    }
}
