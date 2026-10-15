import AppKit
import SwiftUI

/// Everything a person can change about the Projects sidebar. Templates are
/// presets of it; the Customize popover edits it live. Stored as a flat
/// key/value dictionary so new knobs never break a saved style.
struct SidebarProjectsStyle: Equatable {
    enum GroupBy: String, CaseIterable { case project, machine, status, none }
    enum Indent: String, CaseIterable { case aligned, indented, tree }
    enum Density: String, CaseIterable { case compact, regular, roomy }
    enum Lines: String, CaseIterable { case one, two }
    enum Title: String, CaseIterable { case name, task, directory, branch }
    enum Detail: String, CaseIterable { case branch, directory, message, machine }
    enum Leading: String, CaseIterable { case status, agent, none }
    enum Status: String, CaseIterable { case marks, words, mono }
    enum Machine: String, CaseIterable { case name, glyph, hidden }
    enum Rows: String, CaseIterable { case rounded, flush }
    enum Headers: String, CaseIterable { case caps, title }
    enum Icon: String, CaseIterable { case letter, color, folder, none }
    enum Accent: String, CaseIterable { case blue, system, purple, pink, orange, green, graphite }
    enum TextSize: String, CaseIterable { case small, medium, large }
    enum Backdrop: String, CaseIterable { case solid, glass }
    enum NewButton: String, CaseIterable { case button, row, hidden }
    enum Pinned: String, CaseIterable { case list, tiles }
    enum Visibility: String, CaseIterable { case always, auto, hidden }
    enum Section: String, CaseIterable { case pinned, groups, loose, machines }

    struct SectionSetting: Equatable, Identifiable {
        var id: Section
        var visibility: Visibility
    }

    var groupBy = GroupBy.project
    var sections: [SectionSetting] = [
        .init(id: .pinned, visibility: .always),
        .init(id: .groups, visibility: .always),
        .init(id: .loose, visibility: .always),
        .init(id: .machines, visibility: .hidden),
    ]
    var indent = Indent.aligned
    var newButton = NewButton.button
    /// Pinned workspaces as rows, or as a grid of tiles like a browser's favorites.
    var pinned = Pinned.list
    var search = true
    var cloudNav = true
    var footer = true
    var density = Density.regular
    var lines = Lines.one
    var title = Title.name
    var detail = Detail.branch
    var leading = Leading.status
    var status = Status.marks
    var agents = true
    var machine = Machine.name
    var time = false
    var diff = false
    var rows = Rows.rounded
    var headers = Headers.caps
    var icon = Icon.letter
    var accent = Accent.blue
    var textSize = TextSize.medium
    var backdrop = Backdrop.solid

    func visibility(_ section: Section) -> Visibility {
        sections.first { $0.id == section }?.visibility ?? .hidden
    }

    /// Whether a section can be hidden without losing workspaces: hidden Pinned
    /// leaves pins in place, and Machines is only a filter.
    static func canHide(_ section: Section) -> Bool { section == .pinned || section == .machines }

    // MARK: Knobs (one per setting, by name: storage, templates and the lab shell)

    struct Knob {
        let key: String
        let options: [String]
        let get: (SidebarProjectsStyle) -> String
        let set: (inout SidebarProjectsStyle, String) -> Void
    }

    private static func knob<E: RawRepresentable & CaseIterable>(
        _ key: String, _ path: WritableKeyPath<SidebarProjectsStyle, E>
    ) -> Knob where E.RawValue == String {
        Knob(key: key, options: E.allCases.map(\.rawValue), get: { $0[keyPath: path].rawValue }) { style, value in
            if let parsed = E(rawValue: value) { style[keyPath: path] = parsed }
        }
    }

    private static func flag(_ key: String, _ path: WritableKeyPath<SidebarProjectsStyle, Bool>) -> Knob {
        Knob(key: key, options: ["on", "off"], get: { $0[keyPath: path] ? "on" : "off" }) { style, value in
            if value == "on" || value == "off" { style[keyPath: path] = value == "on" }
        }
    }

    /// `sections` reads and writes as "pinned:always,groups:always,...".
    private static let sectionsKnob = Knob(
        key: "sections",
        options: [],
        get: { $0.sections.map { "\($0.id.rawValue):\($0.visibility.rawValue)" }.joined(separator: ",") },
        set: { style, value in
            var parsed: [SectionSetting] = []
            for pair in value.split(separator: ",") {
                let parts = pair.split(separator: ":").map(String.init)
                guard parts.count == 2, let id = Section(rawValue: parts[0]), let visibility = Visibility(rawValue: parts[1]),
                      !parsed.contains(where: { $0.id == id }) else { continue }
                parsed.append(SectionSetting(id: id, visibility: visibility))
            }
            for id in Section.allCases where !parsed.contains(where: { $0.id == id }) {
                parsed.append(SectionSetting(id: id, visibility: canHide(id) ? .hidden : .auto))
            }
            // Projects and Workspaces hold workspaces that have nowhere else to go.
            for index in parsed.indices where !canHide(parsed[index].id) && parsed[index].visibility == .hidden {
                parsed[index].visibility = .auto
            }
            style.sections = parsed
        }
    )

    static let knobs: [Knob] = [
        knob("group", \.groupBy), sectionsKnob, knob("indent", \.indent), knob("new", \.newButton), knob("pinned", \.pinned),
        flag("search", \.search), flag("cloud", \.cloudNav), flag("footer", \.footer),
        knob("density", \.density), knob("lines", \.lines), knob("title", \.title), knob("detail", \.detail),
        knob("leading", \.leading), knob("status", \.status), flag("agents", \.agents), knob("machine", \.machine),
        flag("time", \.time), flag("diff", \.diff), knob("rows", \.rows), knob("headers", \.headers),
        knob("icon", \.icon), knob("accent", \.accent), knob("text", \.textSize), knob("backdrop", \.backdrop),
    ]

    var values: [String: String] {
        Dictionary(uniqueKeysWithValues: Self.knobs.map { ($0.key, $0.get(self)) })
    }

    func applying(_ values: [String: String]) -> SidebarProjectsStyle {
        var style = self
        for knob in Self.knobs { if let value = values[knob.key] { knob.set(&style, value) } }
        return style
    }

    // MARK: Templates (presets: a name, one line, and what differs from the default)

    struct Template: Identifiable {
        let name: String
        let summary: String
        let overrides: [String: String]
        var id: String { name }
        var style: SidebarProjectsStyle { SidebarProjectsStyle().applying(overrides) }
    }

    static let templates: [Template] = [
        Template(name: "Projects", summary: "Projects as folders, Cloud as a mark on the row", overrides: [:]),
        Template(name: "Agents", summary: "Which agent, and what it last said", overrides: [
            "lines": "two", "detail": "message", "leading": "agent", "time": "on", "machine": "glyph",
            "icon": "folder", "headers": "title", "new": "row",
        ]),
        Template(name: "Machines", summary: "One section per machine, This Mac first", overrides: [
            "group": "machine", "sections": "pinned:auto,groups:always,loose:auto,machines:hidden", "machine": "hidden",
        ]),
        Template(name: "Inbox", summary: "Sorted by what needs you", overrides: [
            "group": "status", "lines": "two", "detail": "message", "leading": "agent", "time": "on",
            "machine": "glyph", "headers": "title", "new": "row", "cloud": "off",
        ]),
        Template(name: "Flush", summary: "Edge to edge rows, branch and age underneath", overrides: [
            "rows": "flush", "lines": "two", "detail": "branch", "leading": "agent", "time": "on",
            "headers": "title", "icon": "none", "new": "row", "cloud": "off",
        ]),
        Template(name: "Minimal", summary: "Titles only, status in words, on glass", overrides: [
            "leading": "none", "status": "words", "agents": "off", "machine": "glyph", "icon": "none",
            "headers": "title", "new": "hidden", "search": "off", "cloud": "off", "footer": "off",
            "density": "compact", "backdrop": "glass",
        ]),
    ]
}

/// The style in use, saved in UserDefaults, plus whether the Customize popover is open.
@MainActor
final class SidebarProjectsStyleStore: ObservableObject {
    static let shared = SidebarProjectsStyleStore()
    private static let styleKey = "sidebarProjectsStyle"
    private static let templateKey = "sidebarProjectsTemplate"

    @Published var style: SidebarProjectsStyle { didSet { save() } }
    @Published private(set) var templateName: String
    @Published var isCustomizing = false

    private init() {
        let defaults = UserDefaults.standard
        templateName = defaults.string(forKey: Self.templateKey) ?? SidebarProjectsStyle.templates[0].name
        let saved = defaults.dictionary(forKey: Self.styleKey) as? [String: String] ?? [:]
        style = SidebarProjectsStyle().applying(saved)
    }

    var template: SidebarProjectsStyle.Template {
        SidebarProjectsStyle.templates.first { $0.name == templateName } ?? SidebarProjectsStyle.templates[0]
    }

    /// The style no longer matches the template it started from.
    var isEdited: Bool { style != template.style }

    func use(_ template: SidebarProjectsStyle.Template) {
        templateName = template.name
        style = template.style
    }

    func reset() { style = template.style }

    /// Sets one knob by name ("indent", "tree"); false when the name or value is unknown.
    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        guard let knob = SidebarProjectsStyle.knobs.first(where: { $0.key == key }),
              knob.options.isEmpty || knob.options.contains(value) else { return false }
        var next = style
        knob.set(&next, value)
        style = next
        return true
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(style.values, forKey: Self.styleKey)
        defaults.set(templateName, forKey: Self.templateKey)
    }
}

/// The sidebar's colors: a neutral ground and text ramp, plus the chosen accent.
struct SidebarProjectsPalette {
    let bg, raise, label, label2, label3, sep, need, err, add, del, accent: Color
    let isDark: Bool

    /// A wash of the foreground: hover, selection, tiles.
    func wash(_ opacity: Double) -> Color { (isDark ? Color.white : Color.black).opacity(opacity) }

    init(dark: Bool, accent: SidebarProjectsStyle.Accent) {
        func hex(_ value: UInt32) -> Color {
            Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
        }
        isDark = dark
        bg = hex(dark ? 0x0A0A0A : 0xFAFAFA)
        raise = dark ? hex(0x171717) : .white
        label = hex(dark ? 0xEDEDED : 0x171717)
        label2 = hex(dark ? 0xA3A3A3 : 0x707070)
        label3 = hex(dark ? 0x6B6B6B : 0xA3A3A3)
        sep = hex(dark ? 0x262626 : 0xE5E5E5)
        need = hex(dark ? 0xE0A93B : 0xB7791F)
        err = hex(dark ? 0xF0565B : 0xD93036)
        add = hex(dark ? 0x4CC38A : 0x1A7F4B)
        del = hex(dark ? 0xF0565B : 0xD93036)
        switch accent {
        case .blue: self.accent = hex(dark ? 0x0091FF : 0x0073D9)
        case .system: self.accent = Color.accentColor
        case .purple: self.accent = hex(dark ? 0xA78BFA : 0x7C3AED)
        case .pink: self.accent = hex(dark ? 0xF472B6 : 0xDB2777)
        case .orange: self.accent = hex(dark ? 0xFB923C : 0xEA580C)
        case .green: self.accent = hex(dark ? 0x4ADE80 : 0x16A34A)
        case .graphite: self.accent = hex(dark ? 0xA3A3A3 : 0x525252)
        }
    }
}
