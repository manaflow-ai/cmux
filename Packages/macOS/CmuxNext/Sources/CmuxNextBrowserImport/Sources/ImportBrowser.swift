import Foundation

/// The browser engine family a source belongs to, which decides the file
/// formats its profiles use.
public enum BrowserFamily: String, Sendable, Codable {
    case chromium
    case firefox
    case safari
}

/// A browser cmux can import from. Paths are relative to the user's home
/// directory, so tests point the detector at a fixture home.
public enum ImportBrowser: String, Sendable, Codable, CaseIterable, Identifiable {
    case chrome, arc, dia, brave, edge, vivaldi, helium, chromium, safari, firefox

    public var id: String { rawValue }

    /// Product names are not translated.
    public var displayName: String {
        switch self {
        case .chrome: "Google Chrome"
        case .arc: "Arc"
        case .dia: "Dia"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .helium: "Helium"
        case .chromium: "Chromium"
        case .safari: "Safari"
        case .firefox: "Firefox"
        }
    }

    public var family: BrowserFamily {
        switch self {
        case .safari: .safari
        case .firefox: .firefox
        default: .chromium
        }
    }

    /// Bundle identifiers, most common first (used to find the app and its icon).
    public var bundleIDs: [String] {
        switch self {
        case .chrome: ["com.google.Chrome"]
        case .arc: ["company.thebrowser.Browser"]
        case .dia: ["company.thebrowser.dia"]
        case .brave: ["com.brave.Browser"]
        case .edge: ["com.microsoft.edgemac"]
        case .vivaldi: ["com.vivaldi.Vivaldi"]
        case .helium: ["net.imput.helium"]
        case .chromium: ["org.chromium.Chromium"]
        case .safari: ["com.apple.Safari"]
        case .firefox: ["org.mozilla.firefox"]
        }
    }

    /// The data directory, relative to home. For Chromium browsers this is
    /// the "user data dir" that holds `Local State` and the profile folders.
    public var dataDirectory: String {
        switch self {
        case .chrome: "Library/Application Support/Google/Chrome"
        case .arc: "Library/Application Support/Arc/User Data"
        case .dia: "Library/Application Support/Dia/User Data"
        case .brave: "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: "Library/Application Support/Microsoft Edge"
        case .vivaldi: "Library/Application Support/Vivaldi"
        case .helium: "Library/Application Support/net.imput.helium"
        case .chromium: "Library/Application Support/Chromium"
        case .safari: "Library/Safari"
        case .firefox: "Library/Application Support/Firefox"
        }
    }

    /// Whether the store lists this browser's extensions (Chrome Web Store).
    public var sharesChromeWebStore: Bool { family == .chromium }
}
