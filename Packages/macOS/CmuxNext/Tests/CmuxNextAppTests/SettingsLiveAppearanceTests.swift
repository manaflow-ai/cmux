import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextTabs
import Testing

/// The Settings page's real provider, writer and renderer, with an isolated config file.
/// A preview must reach an already-mounted indicator before the bridge answers; a committed
/// value and its reset must reach both native type and the first-party page's CSS scale.
@MainActor @Suite(.serialized) struct SettingsLiveAppearanceTests {
    private func withPage(_ body: (SettingsPageProvider, SettingsController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "settings-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux-next.json")
        try Data("{}".utf8).write(to: url)
        let design = DesignSettings.shared
        let density = design.densityTokens, indicator = design.statusIndicator
        let overrides = design.overrides, uiScale = design.uiScale
        defer {
            design.densityTokens = density
            design.statusIndicator = indicator
            design.uiScale = uiScale
            for key in MetricKey.allCases { design.setOverride(key, overrides[key]) }
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try await body(SettingsPageProvider(settings: settings), settings)
    }

    private func call(_ page: SettingsPageProvider, _ op: String, _ key: String, _ value: JSONValue? = nil) async throws {
        var params: JSONValue = ["key": .string(key)]
        if let value, case .object(var members) = params {
            members["value"] = value
            params = .object(members)
        }
        _ = try await page.call("cmux.settings.\(op)", params: params, context: PageCallContext(page: "cmux.settings"))
    }

    @Test func previewRestylesAnExistingLoadingTabBeforeReplying() async throws {
        try await withPage { page, _ in
            var item = TabItem(id: TabID("loading"), title: "Loading")
            item.indicator = .busy(progress: nil)
            let cell = TabCell(item: item)
            #expect(cell.spinnerLayer?.plan.glyph == .arc)
            try await call(page, "preview", "appearance.statusIndicator.style", .string("dot"))
            #expect(cell.spinnerLayer?.plan.glyph == .dot)
            try await call(page, "preview", "appearance.statusIndicator.thickness", .number(3))
            #expect(cell.spinnerLayer?.glyphLayer?.lineWidth == 3)
            try await call(page, "preview", "appearance.statusIndicator.size", .number(1.5))
            let spinner = try #require(cell.spinnerLayer)
            #expect(spinner.glyphRect.width == min(spinner.frame.width, spinner.frame.height) * 1.5)
            try await call(page, "preview", "appearance.statusIndicator.animation", .string("static"))
            #expect(cell.spinnerLayer?.plan.animation == nil)
            try await call(page, "preview.end", "appearance.statusIndicator.animation")
            #expect(cell.spinnerLayer?.config.settings.animation == .animated)
        }
    }

    @Test func interfaceSizeReachesNativeAndWebTypeAndResetsThroughThePage() async throws {
        try await withPage { page, settings in
            let nativeDefault = TypeScale.body
            try await call(page, "set", "appearance.metrics.chromeFontSize", .number(16))
            #expect(Typography.body.pointSize == 16)
            #expect(TypeScale.body > nativeDefault)
            #expect(DesignSettings.shared.interfaceScaleScript.contains("'\(Typography.userScale)'"))
            let descriptor = try #require(SettingsSchema.descriptor(for: ["appearance", "metrics", "chromeFontSize"]))
            #expect(settings.isCustomized(descriptor))
            try await call(page, "reset", descriptor.id)
            #expect(TypeScale.body == nativeDefault)
            #expect(!settings.isCustomized(descriptor))
            #expect(try await settings.file.value(at: descriptor.path) == nil)
        }
    }

    @Test func committedControlsApplyWithoutAFileWatcherAndSurviveReload() async throws {
        try await withPage { page, settings in
            let values: [(String, JSONValue)] = [
                ("appearance.statusIndicator.style", .string("braille")),
                ("appearance.statusIndicator.animation", .string("static")),
                ("appearance.statusIndicator.size", .number(1.5)),
                ("appearance.statusIndicator.thickness", .number(3)),
                ("appearance.statusIndicator.showAgentWorkingOnTabs", .bool(false)),
                ("appearance.statusIndicator.showPageLoading", .bool(false)),
                ("appearance.statusIndicator.honorStatusStyle", .bool(false)),
                ("appearance.density", .string("comfortable")),
                ("app.uiScale", .number(1.25)),
            ]
            for (key, value) in values {
                try await call(page, "set", key, value)
                #expect(settings.snapshot.root.value(at: key.split(separator: ".").map(String.init)) == value)
            }
            let live = DesignSettings.shared.statusIndicator
            #expect(live.style == .braille && live.animation == .static)
            #expect(live.scale == 1.5 && live.thickness == 3)
            #expect(!live.showsAgentWorkingOnTabs && !live.showsPageLoading && live.honoredStyleSources.isEmpty)
            #expect(DesignSettings.shared.uiScale == 1.25)
            await settings.reload()
            #expect(DesignSettings.shared.statusIndicator == live)
            for (key, _) in values { try await call(page, "reset", key) }
            #expect(DesignSettings.shared.statusIndicator == StatusIndicatorSettings())
            #expect(DesignSettings.shared.uiScale == 1)
        }
    }
}
