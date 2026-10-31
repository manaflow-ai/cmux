import os

/// `tabs.newTabWidgets.order` in cmux.json: the order the New Tab page shows its movable widgets
/// in, as its edit mode leaves it (right-click the page > Edit New Tab, then drag a widget):
///
/// ```jsonc
/// "tabs": { "newTabWidgets": { "chats": true, "projects": true, "order": ["chats", "projects"] } }
/// ```
///
/// A widget's place does not turn it on; its own key does. Widgets left out follow in Settings'
/// order, and a bad or repeated item is dropped with a diagnostic. The headline stays over the
/// composer, and the template dots stay where they are.
nonisolated extension NewTabWidgetSettings {
    public static let orderPath = ["tabs", "newTabWidgets", "order"]
    /// The widgets the edit mode moves, in Settings' order: the default order.
    public static let movable = ["projects", "actions", "chats"]

    static func parseOrder(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> [String] {
        guard let value = root.value(at: orderPath) else { return movable }
        let id = orderPath.joined(separator: ".")
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an array of widget names"))
            return movable
        }
        let known = items.compactMap(\.stringValue).filter(movable.contains)
        var order: [String] = []
        for item in known where !order.contains(item) { order.append(item) }
        if order.count != items.count {
            let list = movable.map { "\"\($0)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected each of \(list) at most once"))
        }
        return completed(order)
    }

    /// `saved` with the widgets in `shown` put in `shown`'s order, in the places they held; the
    /// others stay where they are.
    static func reordered(_ saved: [String], shown: [String]) -> [String] {
        var seen = Set<String>()
        let moved = shown.filter { movable.contains($0) && seen.insert($0).inserted }
        var next = moved.makeIterator()
        return completed(completed(saved).map { moved.contains($0) ? (next.next() ?? $0) : $0 })
    }

    /// `order`'s movable widgets, then the ones it leaves out in Settings' order.
    static func completed(_ order: [String]) -> [String] {
        let known = order.filter(movable.contains)
        return known + movable.filter { !known.contains($0) }
    }

    /// The order's row, after the generated switches (SettingsSchema+NewTabWidgets.generated.swift).
    static var editDescriptors: [SettingDescriptor] { [orderDescriptor(group: SettingsText.keyed("settings.group.tabs", "Tabs"))] }

    static func orderDescriptor(group: SettingText) -> SettingDescriptor {
        let titles = [
            SettingsText.keyed("settings.tabs.newTabWidgets.order.projects", "Projects"),
            SettingsText.keyed("settings.tabs.newTabWidgets.order.actions", "Quick Actions"),
            SettingsText.keyed("settings.tabs.newTabWidgets.order.chats", "Recent Chats"),
        ]
        return SettingDescriptor(
            orderPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabWidgets.order", "New Tab Widget Order"),
            help: SettingsText.keyed("settings.tabs.newTabWidgets.order.help",
                                     "The order of the widgets on New Tab. Right-click New Tab and choose Edit New Tab to drag them."),
            kind: .orderedChoices(zip(movable, titles).map { SettingChoice($0, $1) }),
            default: .array(movable.map(JSONValue.string)), keywords: ["new tab", "widget", "order", "arrange", "edit"]
        )
    }
}

extension SettingsController {
    /// The New Tab page's ✕ in edit mode: turns the widget off as its Settings switch does (a
    /// widget that is off by default leaves the file). The page names only widgets it shows.
    public func removeNewTabWidget(_ widget: String) async throws {
        let path = ["tabs", "newTabWidgets", widget]
        guard let descriptor = SettingsSchema.descriptor(for: path), descriptor.kind == .toggle else {
            throw SettingNotInSchema(key: path.joined(separator: "."))
        }
        try await setSetting(descriptor, to: descriptor.defaultValue == .bool(true) ? .bool(false) : nil, by: .caller("page"))
    }

    /// The New Tab page's second dot (Claude Minimal with the quick actions, webviews
    /// newtab/tabDots.ts): turns the widget on as its Settings switch does (a widget that is on by
    /// default leaves the file).
    public func showNewTabWidget(_ widget: String) async throws {
        let path = ["tabs", "newTabWidgets", widget]
        guard let descriptor = SettingsSchema.descriptor(for: path), descriptor.kind == .toggle else {
            throw SettingNotInSchema(key: path.joined(separator: "."))
        }
        try await setSetting(descriptor, to: descriptor.defaultValue == .bool(true) ? nil : .bool(true), by: .caller("page"))
    }

    /// The New Tab page's drag in edit mode: the movable widgets it shows, in their new order. A
    /// widget it does not show (off) keeps its place in the saved order; the default order leaves
    /// the file.
    public func setNewTabWidgetOrder(_ shown: [String]) async throws {
        let order = NewTabWidgetSettings.reordered(snapshot.newTabWidgets.order, shown: shown)
        let value: JSONValue? = order == NewTabWidgetSettings.movable ? nil : .array(order.map(JSONValue.string))
        try await setSetting(at: NewTabWidgetSettings.orderPath, to: value, by: .caller("page"))
    }

    /// Runs a page's write, logging a refusal: the page already shows the edit, and the next New Tab
    /// shows what the file says.
    public func logged(_ what: String, _ write: () async throws -> Void) async {
        do { try await write() } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                .error("\(what, privacy: .public) write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The New Tab page's style switch, saved as `tabs.newTabTemplate` through the schema as the
    /// Settings window writes it. Terminal and unknown values are ignored: New Tab never opens a
    /// terminal by itself.
    public func saveNewTabTemplate(_ value: String) async {
        guard let template = NewTabTemplate(rawValue: value), template != .terminal,
              let descriptor = SettingsSchema.descriptor(for: NewTabTemplate.configPath) else { return }
        // The old Composer page is no longer selectable. Normalize page writes too, so a stale
        // caller cannot put the retired value back into cmux.json.
        let savedTemplate: NewTabTemplate = template == .composer ? .minimal : template
        do { try await setSetting(descriptor, to: .string(savedTemplate.rawValue), by: .caller("page")) } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "newtab")
                .error("new tab template write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
