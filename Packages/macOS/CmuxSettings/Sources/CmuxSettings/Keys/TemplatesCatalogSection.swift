import Foundation

/// JSON-backed customization keys for structured-text panel templates.
public struct TemplatesCatalogSection: SettingCatalogSection {
    /// Markdown template typography and CSS fields.
    public let markdown = PanelTemplateCatalog(prefix: "templates.markdown")
    /// Project-scoped note template typography and CSS fields.
    public let notes = PanelTemplateCatalog(prefix: "templates.notes")
    /// Diff template typography and CSS fields.
    public let diff = PanelTemplateCatalog(prefix: "templates.diff", fontSize: 10, lineHeight: 20)

    public init() {}
}

/// The editable fields shared by markdown and diff template entries.
public struct PanelTemplateCatalog: SettingCatalogSection {
    public let font: JSONKey<String>
    public let fontSize: JSONKey<Double>
    public let lineHeight: JSONKey<Double>
    public let cssOverlay: JSONKey<String>
    public let headerExtensions: JSONKey<String>
    public let footerExtensions: JSONKey<String>

    public init(prefix: String, fontSize: Double = 15, lineHeight: Double = 1.5) {
        self.font = JSONKey(id: "\(prefix).font", defaultValue: "")
        self.fontSize = JSONKey(id: "\(prefix).fontSize", defaultValue: fontSize)
        self.lineHeight = JSONKey(id: "\(prefix).lineHeight", defaultValue: lineHeight)
        self.cssOverlay = JSONKey(id: "\(prefix).cssOverlay", defaultValue: "")
        self.headerExtensions = JSONKey(id: "\(prefix).headerExtensions", defaultValue: "")
        self.footerExtensions = JSONKey(id: "\(prefix).footerExtensions", defaultValue: "")
    }
}
