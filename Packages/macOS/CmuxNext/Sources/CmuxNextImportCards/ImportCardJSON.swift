import AppKit
import CmuxNextImportSuggestions
import CmuxNextSettings

/// A card list as the web surfaces read it (Settings' host lists `import_suggestions`,
/// `import.list`): the Codable cards, each with its source app's icon as a small
/// `data:image/png` URL (a cmux page's CSP allows `img-src data:` only).
@MainActor
struct ImportCardJSON {
    /// Null for an empty list: the surface draws nothing and keeps no room.
    static func value(_ list: ImportCardList, icons: Bool = true, keepEmpty: Bool = false) -> JSONValue {
        guard keepEmpty || !list.cards.isEmpty, let data = try? JSONEncoder().encode(list),
              let object = try? JSONSerialization.jsonObject(with: data), var value = JSONValue(foundation: object) else { return .null }
        if icons, case .object(var members) = value, case .array(let cards) = members["cards"] {
            members["cards"] = .array(cards.map { card in
                guard case .object(var fields) = card, let app = fields["app"]?.stringValue, let icon = ImportAppIcons.dataURL(app) else { return card }
                fields["icon"] = .string(icon)
                return .object(fields)
            })
            value = .object(members)
        }
        return value
    }

    /// The list as JSON text (`import.list`'s `cards` field).
    static func text(_ list: ImportCardList) -> String {
        value(list, icons: false).compactText
    }
}

/// Source apps' icons, from Launch Services only (no file of the app is read), cached per bundle id.
@MainActor
struct ImportAppIcons {
    /// Points; drawn at 2x.
    static let side: CGFloat = 32
    private static var cache: [String: String?] = [:]

    static func image(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func dataURL(_ bundleID: String) -> String? {
        if let cached = cache[bundleID] { return cached }
        let url = image(bundleID).flatMap(png).map { "data:image/png;base64," + $0.base64EncodedString() }
        cache[bundleID] = url
        return url
    }

    private static func png(_ image: NSImage) -> Data? {
        let pixels = Int(side * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }
}
