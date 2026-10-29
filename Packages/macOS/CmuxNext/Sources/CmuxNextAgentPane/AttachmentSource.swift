public import Foundation

/// The app an attachment came from, worn as a small icon at its chip's top-right corner. Leo,
/// 2026-10-29: "Also, I guess it's, like, you know, be interesting to add, like, attributions for
/// screenshots and attachments and whatnot, right? I think, like, Spotlight has an interesting
/// feature for that, where just at the top right, there's a little icon that says, Oh, hey, this
/// came from Cmax, this came from Claude, or whatever."
///
/// A source is only ever what the system records: a file's own metadata (AttachmentSourceFiles.swift),
/// the app a pasteboard says wrote it (AttachmentPasteboardOrigin.swift), or cmux's own capture. An
/// unknown source is none, and its chip wears no icon: never a guess.
public nonisolated struct AttachmentSource: Codable, Sendable, Equatable {
    /// The app's name as the person knows it ("Google Chrome", "Screenshot", "cmux").
    public var name: String
    /// The app's bundle identifier, which its icon is read by (``AttachmentSourceIcons``).
    public var bundleId: String?
    /// The website a downloaded file came from: its host only, never a path or query.
    public var site: String?

    nonisolated static let maximumName = 64
    nonisolated static let maximumBundleId = 255
    nonisolated static let maximumSite = 253

    /// A source, or nil when `name` is empty or too long, or `bundleId` or `site` is not one.
    public init?(name: String, bundleId: String? = nil, site: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumName else { return nil }
        if let bundleId, !Self.isBundleId(bundleId) { return nil }
        if let site, !Self.isSite(site) { return nil }
        (self.name, self.bundleId, self.site) = (trimmed, bundleId, site)
    }

    /// A source this file made from values already checked.
    private init(checked name: String, bundleId: String?) {
        (self.name, self.bundleId, self.site) = (name, bundleId, nil)
    }

    /// The page's `{name, bundleId?, site?}`.
    public var json: [String: String] {
        var value = ["name": name]
        if let bundleId { value["bundleId"] = bundleId }
        if let site { value["site"] = site }
        return value
    }

    /// A reverse-DNS identifier: letters, digits, `.`, `-` and `_`, with a dot, not starting with one.
    nonisolated static func isBundleId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBundleId, value.contains("."), !value.hasPrefix(".") else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// A host name: letters, digits, `.` and `-`, lowercase.
    nonisolated static func isSite(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumSite, value == value.lowercased() else { return false }
        return value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-".unicodeScalars.contains($0)) }
    }

    /// This app: its own captures (Attach Screenshot…, Screenshot Tab) and its own copies.
    public static var cmux: AttachmentSource {
        AttachmentSource(checked: "cmux", bundleId: Bundle.main.bundleIdentifier.flatMap { isBundleId($0) ? $0 : nil })
    }

    /// macOS's Screenshot app: a screen capture's file, or a capture it put on the pasteboard.
    public static let screenshot = AttachmentSource(checked: "Screenshot", bundleId: screenshotBundleId)
    nonisolated static let screenshotBundleId = "com.apple.screenshot.launcher"
}
