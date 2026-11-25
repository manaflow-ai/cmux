public import CoreGraphics
public import Foundation
public import CmuxNextDesignTokens

/// What a page's glass lenses (the `cmuxTheme.backdrop` payload, plans/cmux-next/glass-lens-DESIGN.md),
/// without the image itself: `key` names it, so a push compares and carries the large data URL
/// only when the image changed.
public nonisolated struct GlassBackdropPayload: Equatable, Sendable {
    /// Changes exactly when the image does; nil when there is no still to refract.
    public var key: String?
    /// The art's aspect-filled rect in the page's CSS px; nil without a still.
    public var rect: GlassBackdropRect?
    /// The art's own blur radius, in CSS px.
    public var blur: Double
    /// The native wash over the art, as a CSS color with alpha, or `transparent`.
    public var tint: String

    public init(key: String?, rect: GlassBackdropRect?, blur: Double, tint: String) {
        self.key = key
        self.rect = rect
        self.blur = blur
        self.tint = tint
    }

    /// No still: the page's glass shows plain blur glass.
    public static let none = GlassBackdropPayload(key: nil, rect: nil, blur: 0, tint: "transparent")

    /// The fields that differ from `sent` (every field when nothing was sent), with `image` (the
    /// data URL `key` names) only when the key changed; nil when the page has all of them.
    public func changes(since sent: GlassBackdropPayload?, image: String?) -> [String: Any]? {
        var fields: [String: Any] = [:]
        if sent == nil || sent?.key != key {
            fields["key"] = key ?? NSNull()
            fields["image"] = (key == nil ? nil : image) ?? NSNull()
        }
        if sent == nil || sent?.rect != rect { fields["rect"] = rect?.json ?? NSNull() }
        if sent == nil || sent?.blur != blur { fields["blur"] = blur }
        if sent == nil || sent?.tint != tint { fields["tint"] = tint }
        return fields.isEmpty ? nil : fields
    }

    /// The script that hands `fields` to a page that ran ``WebTheme/bootstrapScript``.
    public static func script(_ fields: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "window.cmuxTheme && window.cmuxTheme.backdrop && window.cmuxTheme.backdrop(\(json));"
    }

    /// `rgba(r, g, b, a)` for `color` in sRGB, or `transparent` for none or a clear one.
    public static func css(_ color: CGColor?) -> String {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let srgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = srgb.components, parts.count >= 3, srgb.alpha > 0 else { return "transparent" }
        return WebTheme.css(ThemeRGB(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]), alpha: Double(srgb.alpha)))
    }
}
