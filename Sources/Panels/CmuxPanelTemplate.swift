import Foundation

/// The shared, JSON-backed presentation contract for structured-text panels.
///
/// Templates are intentionally small value types. A panel starts with its
/// built-in template and overlays only the fields present in `cmux.json`, so
/// adding a new optional field never changes existing users' rendering.
struct CmuxPanelTemplate: Codable, Equatable, Sendable {
    enum Alignment: String, Codable, Sendable {
        case leading
        case center
        case trailing
    }

    struct Viewport: Codable, Equatable, Sendable {
        var maxWidth: Double?
        var padding: Double?
        var alignment: Alignment?

        init(maxWidth: Double? = nil, padding: Double? = nil, alignment: Alignment? = nil) {
            self.maxWidth = maxWidth
            self.padding = padding
            self.alignment = alignment
        }

        private enum CodingKeys: String, CodingKey { case maxWidth, padding, alignment }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxWidth = try container.decodeIfPresent(Double.self, forKey: .maxWidth)
                .map { min(4000, max(200, $0)) }
            padding = try container.decodeIfPresent(Double.self, forKey: .padding)
                .map { min(160, max(0, $0)) }
            alignment = try container.decodeIfPresent(Alignment.self, forKey: .alignment)
        }
    }

    var font: String?
    var fontSize: Double?
    var lineHeight: Double?
    var theme: String?
    var lightTheme: String?
    var darkTheme: String?
    var cssOverlay: String?
    var viewport: Viewport?
    var headerExtensions: String?
    var footerExtensions: String?

    static let markdownDefault = CmuxPanelTemplate(
        font: nil,
        fontSize: 15,
        lineHeight: 1.5,
        theme: nil,
        lightTheme: nil,
        darkTheme: nil,
        cssOverlay: nil,
        viewport: Viewport(maxWidth: 980, padding: 32, alignment: .leading),
        headerExtensions: nil,
        footerExtensions: nil
    )

    static let diffDefault = CmuxPanelTemplate(
        font: "Menlo",
        fontSize: 10,
        lineHeight: 20,
        theme: nil,
        lightTheme: nil,
        darkTheme: nil,
        cssOverlay: nil,
        viewport: nil,
        headerExtensions: nil,
        footerExtensions: nil
    )

    static let notesDefault = markdownDefault

    private init(
        font: String?,
        fontSize: Double?,
        lineHeight: Double?,
        theme: String?,
        lightTheme: String?,
        darkTheme: String?,
        cssOverlay: String?,
        viewport: Viewport?,
        headerExtensions: String?,
        footerExtensions: String?
    ) {
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.theme = theme
        self.lightTheme = lightTheme
        self.darkTheme = darkTheme
        self.cssOverlay = cssOverlay
        self.viewport = viewport
        self.headerExtensions = headerExtensions
        self.footerExtensions = footerExtensions
    }

    private enum CodingKeys: String, CodingKey {
        case font, fontFamily, fontSize, lineHeight, theme, lightTheme, darkTheme
        case cssOverlay, viewport, headerExtensions, footerExtensions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawFont = try container.decodeIfPresent(String.self, forKey: .font)
            ?? (try container.decodeIfPresent(String.self, forKey: .fontFamily))
        let normalizedFont = rawFont?.trimmingCharacters(in: .whitespacesAndNewlines)
        font = normalizedFont?.isEmpty == true ? nil : normalizedFont
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
            .map { min(96, max(8, $0)) }
        lineHeight = try container.decodeIfPresent(Double.self, forKey: .lineHeight)
            .map { min(80, max(0.5, $0)) }
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        lightTheme = try container.decodeIfPresent(String.self, forKey: .lightTheme)
        darkTheme = try container.decodeIfPresent(String.self, forKey: .darkTheme)
        cssOverlay = try container.decodeIfPresent(String.self, forKey: .cssOverlay)
        viewport = try container.decodeIfPresent(Viewport.self, forKey: .viewport)
        headerExtensions = try container.decodeIfPresent(String.self, forKey: .headerExtensions)
        footerExtensions = try container.decodeIfPresent(String.self, forKey: .footerExtensions)
    }

    func merged(over base: CmuxPanelTemplate) -> CmuxPanelTemplate {
        CmuxPanelTemplate(
            font: font ?? base.font,
            fontSize: fontSize ?? base.fontSize,
            lineHeight: lineHeight ?? base.lineHeight,
            theme: theme ?? base.theme,
            lightTheme: lightTheme ?? base.lightTheme,
            darkTheme: darkTheme ?? base.darkTheme,
            cssOverlay: cssOverlay ?? base.cssOverlay,
            viewport: mergedViewport(over: base.viewport),
            headerExtensions: headerExtensions ?? base.headerExtensions,
            footerExtensions: footerExtensions ?? base.footerExtensions
        )
    }

    private func mergedViewport(over base: Viewport?) -> Viewport? {
        guard let viewport else { return base }
        guard let base else { return viewport }
        return Viewport(
            maxWidth: viewport.maxWidth ?? base.maxWidth,
            padding: viewport.padding ?? base.padding,
            alignment: viewport.alignment ?? base.alignment
        )
    }
}

/// Persists the two panel templates through the settings-file import path.
/// The values are encoded as JSON strings because the settings importer already
/// provides atomic replacement, backups, and live UserDefaults notifications.
enum CmuxPanelTemplateStore {
    static let markdownKey = "cmux.template.markdown"
    static let notesKey = "cmux.template.notes"
    static let diffKey = "cmux.template.diff"

    static func resolvedMarkdown(
        filePath: String? = nil,
        defaults: UserDefaults = .standard
    ) -> CmuxPanelTemplate {
        if let filePath, isNotePath(filePath) {
            return resolvedNotes(defaults: defaults)
        }
        return decode(defaults.string(forKey: markdownKey))?.merged(over: .markdownDefault) ?? .markdownDefault
    }

    static func resolvedNotes(defaults: UserDefaults = .standard) -> CmuxPanelTemplate {
        decode(defaults.string(forKey: notesKey))?.merged(over: .notesDefault) ?? .notesDefault
    }

    static func resolvedDiff(defaults: UserDefaults = .standard) -> CmuxPanelTemplate {
        decode(defaults.string(forKey: diffKey))?.merged(over: .diffDefault) ?? .diffDefault
    }

    static func encoded(_ template: CmuxPanelTemplate) -> String? {
        guard let data = try? JSONEncoder().encode(template) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decode(_ value: String?) -> CmuxPanelTemplate? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CmuxPanelTemplate.self, from: data)
    }

    private static func isNotePath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized.contains("/.cmux/notes/")
    }
}
