import Foundation

extension LinkPreview {
    /// The owner's limits (`link-preview.ts` LINK_PREVIEW_LIMITS, Rust `link_preview.rs`).
    public static let maxURLBytes = 2048
    public static let maxTitleScalars = 300
    public static let maxSiteScalars = 253

    /// The part a sender attaches for `url`, as the owner accepts it: the
    /// title and site with control characters as spaces, trimmed and cut at
    /// the owner's limits (empty: left out); a picture the owner would
    /// refuse (not JPEG or WebP, empty or over `previewMaxBytes`, not a
    /// SHA-256) is left out. Nil when the owner refuses the URL itself (not
    /// http or https, over 2048 bytes, user info, whitespace, control
    /// characters or a backslash): the sender sends that line as text.
    public static func sendable(url: String, title: String?, site: String?, image: AttachmentDerivedImage?) -> LinkPreview? {
        guard isSendableURL(url) else { return nil }
        let image = image.flatMap { image -> AttachmentDerivedImage? in
            let hex = image.hash.utf8.count == 64 && image.hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            guard hex, HomeAttachmentPolicy.posterTypes.contains(image.mimeType),
                  (1...HomeAttachmentPolicy.previewMaxBytes).contains(image.byteCount) else { return nil }
            return image
        }
        return LinkPreview(url: url, title: label(title, max: maxTitleScalars), site: label(site, max: maxSiteScalars), image: image)
    }

    /// The owner's `validLinkUrl`: a plain rule, not URL parsing.
    static func isSendableURL(_ url: String) -> Bool {
        guard !url.isEmpty, url.utf8.count <= maxURLBytes,
              !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.isWhitespace || $0 == "\\" })
        else { return false }
        let lower = url.prefix(8).lowercased()
        let rest: Substring
        if lower.hasPrefix("https://") {
            rest = url.dropFirst(8)
        } else if lower.hasPrefix("http://") {
            rest = url.dropFirst(7)
        } else {
            return false
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !authority.isEmpty && !authority.contains("@")
    }

    private static func label(_ value: String?, max: Int) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: cleaned.unicodeScalars.prefix(max))
        let result = String(cut).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
