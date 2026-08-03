public import AppKit

/// Framework-neutral light or dark appearance used by native window chrome.
public enum WindowChromeColorScheme: String, Sendable, Equatable {
    case light
    case dark

    /// Resolves the effective scheme for an AppKit appearance.
    public init(appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// AppKit appearance name for controls that need an explicit override.
    public var appearanceName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}
