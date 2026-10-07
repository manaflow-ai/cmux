import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// One cmux.json, two apps (cmux-next and cmux-browser): every key names the apps that read it.
/// The export, validation and docs cover every key; the cmux-next Settings page and palette show
/// only keys cmux-next reads, so a cmux-browser key never shows a control that changes nothing.
@Suite struct SettingConsumersTests {
    @Test func everyKeyNamesItsConsumersAndCmuxBrowserKeysStayOutOfCmuxNext() throws {
        let rows = SettingsSchema.all
        #expect(rows.allSatisfy { !$0.consumers.isEmpty })
        let browserOnly = rows.filter { !$0.isShownInCmuxNext }
        #expect(browserOnly.contains { $0.id == "browser.toolbar.home" })
        for row in browserOnly {
            #expect(row.consumers == [.cmuxBrowser], "\(row.id)")
            #expect(!row.isPaletteExposed, "\(row.id) is offered in the cmux-next palette")
            #expect(!SettingsSchema.settings(in: row.section).contains(row), "\(row.id) is a cmux-next Settings row")
            #expect(!CFManagedPreferenceReader.publishedKeys.contains(row.id), "\(row.id) is published for MDM")
            #expect(SettingsSchema.agentSettableKeys.contains(row.id), "cmux-browser writes \(row.id) as script")
        }
        // cmux-browser #567 reads these from cmux.json too.
        for key in ["appearance.theme", "appearance.backgroundBlur", "ui.animationSpeed", "focusRing.enabled", "focusRing.width",
                    "focusRing.color", "layout.defaultColumnWidth", "layout.minimumPaneWidth", "app.quitBehavior",
                    "appearance.surfaces.tabBar.color", "appearance.surfaces.browserChrome.color", "appearance.surfaces.sidebar.color",
                    "appearance.metrics.sidebarWidth", "appearance.metrics.columnGap", "appearance.metrics.titlebarHeight"] {
            let row = try #require(SettingsSchema.all.first { $0.id == key })
            #expect(row.consumers == [.cmuxNext, .cmuxBrowser], "\(key)")
            #expect(SettingsSchema.settings(in: row.section).contains(row), "\(key)")
        }
    }

    /// A page-hidden key (raw workspace ids) stays in validation, the export and the agent policy,
    /// but the Settings page and the palette leave it out; the sidebar row menu edits it.
    @Test func aPageHiddenKeyIsWritableButNotOnTheSettingsPage() throws {
        let muted = try #require(SettingsSchema.descriptor(for: ["notifications", "mutedWorkspaces"]))
        #expect(muted.kind == .stringList)
        #expect(muted.consumers == [.cmuxNext, .cmuxBrowser])
        #expect(muted.isShownInCmuxNext && !muted.isShownOnSettingsPage)
        #expect(!muted.isPaletteExposed)
        #expect(!SettingsSchema.settings(in: muted.section).contains(muted))
        #expect(SettingsSchema.agentSettableKeys.contains(muted.id))
        #expect(muted.accepts(["ws-1", "ws-2"]) && !muted.accepts([""]) && !muted.accepts([1]))
        let export = try SettingsSchemaExport().json(catalog: SettingsSchemaExportTests.catalog())
        let document = try #require(try JSONSerialization.jsonObject(with: Data(export.utf8)) as? [String: Any])
        let rows = try #require(document["rows"] as? [[String: Any]])
        let row = try #require(rows.first { $0["key"] as? String == muted.id })
        #expect(row["kind"] as? String == "string_list")
        #expect(row["page_hidden"] as? Bool == true)
        // Besides mutedWorkspaces only the per-kind row overrides (cmux.json only) are page-hidden.
        let hidden = rows.filter { $0["page_hidden"] as? Bool == true }.compactMap { $0["key"] as? String }
        let overrides = Set(WorkspaceRowKind.allCases.map { "sidebar.workspaceRow.\($0.rawValue)." })
        #expect(hidden.filter { key in !overrides.contains { key.hasPrefix($0) } } == [muted.id])
    }

    /// The export carries `consumers` and the two new kinds with their ranges.
    @Test func theExportCarriesConsumersAndTheNewKinds() throws {
        let export = try SettingsSchemaExport().json(catalog: SettingsSchemaExportTests.catalog())
        let document = try #require(try JSONSerialization.jsonObject(with: Data(export.utf8)) as? [String: Any])
        let rows = try #require(document["rows"] as? [[String: Any]])
        func row(_ key: String) throws -> [String: Any] { try #require(rows.first { $0["key"] as? String == key }) }
        #expect(try row("tabs.newTabKind")["consumers"] as? [String] == ["cmux-next"])
        #expect(try row("appearance.theme")["consumers"] as? [String] == ["cmux-browser", "cmux-next"])
        let presets = try row("layout.columnWidthPresets")
        #expect(presets["kind"] as? String == "number_list")
        #expect(presets["consumers"] as? [String] == ["cmux-browser"])
        #expect((presets["range"] as? [String: Any])?["min"] as? Double == 0.1)
        #expect(presets["default"] as? [Double] == [1, 0.6667, 0.5, 0.3333])
        let icons = try row("sidebar.workspaceIcons")
        #expect(icons["kind"] as? String == "string_map")
        #expect((icons["default"] as? [String: Any])?.isEmpty == true)
        #expect(try row("browser.toolbar.home")["default"] as? Bool == false)
        #expect(try row("browser.toolbar.back")["default"] as? Bool == true)
        #expect(try row("layout.stripMargin")["default"] as? Double == 0)
        #expect(try row("window.trafficLightClearance")["default"] as? Double == 72)
    }

    @Test func theNewKindsValidate() throws {
        let presets = try #require(SettingsSchema.descriptor(for: ["layout", "columnWidthPresets"]))
        #expect(presets.accepts([1, 0.5]))
        #expect(presets.accepts([]))
        #expect(!presets.accepts([0.05]))
        #expect(!presets.accepts([2.5]))
        #expect(!presets.accepts(["1"]))
        #expect(!presets.accepts(0.5))
        let icons = try #require(SettingsSchema.descriptor(for: ["sidebar", "workspaceIcons"]))
        #expect(icons.accepts(["*": "●", "Work": "💼", "Scratch": ""]))
        #expect(!icons.accepts(["Work": 1]))
        #expect(!icons.accepts("💼"))
    }

    /// Each listed metric's range is the design clamp, its defaults the density presets, and the
    /// parser reports an out-of-range value at its key.
    @MainActor @Test func layoutMetricsMatchTheDesignMetrics() {
        let tunables: [String: MetricTunable] = [
            "sidebarWidth": MetricTunables.sidebarWidth, "columnGap": MetricTunables.columnGap, "titlebarHeight": MetricTunables.titlebarHeight,
        ]
        for metric in LayoutMetricSetting.all {
            guard let key = MetricKey(rawValue: metric.name), let tunable = tunables[metric.name] else {
                Issue.record("\(metric.name) is not a MetricKey with a tunable")
                continue
            }
            let range = DesignSettings.allowedRange(key)
            #expect(metric.range == Double(range.lowerBound)...Double(range.upperBound), "\(metric.name)")
            #expect(tunable.key == key, "\(metric.name): cmux.json does not reach the metric")
            #expect(Double(tunable.compact) == metric.compact && Double(tunable.comfortable) == metric.comfortable, "\(metric.name)")
            let names = Set(MetricKey.allCases.map(\.rawValue))
            let outside = CmuxConfigSnapshot.parse(.object(["appearance": .object(["metrics": .object([metric.name: .number(metric.range.upperBound + 1)])])]),
                                                   validDensities: [], validMetrics: names)
            #expect(outside.diagnostics.map(\.path) == ["appearance.metrics.\(metric.name)"])
        }
    }
}
