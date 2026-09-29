public import Foundation

/// Identity of a browser tab. The App layer maps the daemon's canonical tab id
/// (`TabPublicId`) onto this value; the browser module never parses it.
public nonisolated struct BrowserTabID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A fresh random id, for demos and tabs the daemon has not named yet.
    public static func random() -> BrowserTabID {
        BrowserTabID(rawValue: UUID().uuidString)
    }

    public var description: String { rawValue }
}

/// Identity of a browser profile. The daemon owns profile identity; each
/// engine derives its storage from this UUID (plans/cmux-next/browser.md,
/// "Per-profile data dirs").
public nonisolated struct BrowserProfileID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// The built-in profile. It has its own fixed UUID so that its storage is
    /// a normal identified store, never the engine's shared default store.
    public static let `default` = BrowserProfileID(
        rawValue: UUID(uuidString: "8E5C0D1F-2B7A-4F3C-9A61-5D2E7B0C4A11")!
    )

    public var description: String { rawValue.uuidString }
}

/// Identity of the pane that shows a tab. CEF tabs of one pane (and one
/// profile) share a Chromium window, so extensions see one Chrome window per
/// pane. The App layer maps the daemon's pane id onto this value.
public nonisolated struct BrowserPaneID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
