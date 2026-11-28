import Foundation

/// Stores independent wrap and font-size choices for each artifact text kind.
struct ChatArtifactTextPreferences {
    static let minimumFontSize = 8.0
    static let maximumFontSize = 28.0
    static let defaultFontSize = 15.0

    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults,
        keyPrefix: String = "cmux.artifactText"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// Returns the saved wrap choice or the kind-specific default.
    func wrapsLines(for kind: ChatArtifactTextLayoutKind) -> Bool {
        let key = wrapKey(for: kind)
        guard defaults.object(forKey: key) != nil else {
            return kind.defaultWrapsLines
        }
        return defaults.bool(forKey: key)
    }

    /// Saves an explicit wrap choice for one text kind.
    func setWrapsLines(_ wrapsLines: Bool, for kind: ChatArtifactTextLayoutKind) {
        defaults.set(wrapsLines, forKey: wrapKey(for: kind))
    }

    /// Returns the saved, clamped monospaced font size for one text kind.
    func fontSize(for kind: ChatArtifactTextLayoutKind) -> Double {
        guard defaults.object(forKey: fontSizeKey(for: kind)) != nil else {
            return Self.defaultFontSize
        }
        return Self.clamped(defaults.double(forKey: fontSizeKey(for: kind)))
    }

    /// Saves and returns a clamped monospaced font size for one text kind.
    @discardableResult
    func setFontSize(_ fontSize: Double, for kind: ChatArtifactTextLayoutKind) -> Double {
        let clamped = Self.clamped(fontSize)
        defaults.set(clamped, forKey: fontSizeKey(for: kind))
        return clamped
    }

    private func wrapKey(for kind: ChatArtifactTextLayoutKind) -> String {
        "\(keyPrefix).wrap.\(kind.rawValue)"
    }

    private func fontSizeKey(for kind: ChatArtifactTextLayoutKind) -> String {
        "\(keyPrefix).fontSize.\(kind.rawValue)"
    }

    private static func clamped(_ fontSize: Double) -> Double {
        min(max(fontSize, minimumFontSize), maximumFontSize)
    }
}
