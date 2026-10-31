import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFiles
@testable import CmuxNextFilesUI
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The Settings page's real provider, writer and renderer, with an isolated config file.
/// A preview must reach an already-mounted indicator before the bridge answers; a committed
/// value and its reset must reach both native type and the first-party page's CSS scale.
@MainActor @Suite(.serialized, .closesItsWindows) struct SettingsLiveAppearanceTests {
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
            StatusIndicatorAppearance.shared.refresh()
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = SettingsController(registry: ActionRegistry(catalog: []), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        try await body(SettingsPageProvider(settings: settings), settings)
    }

    private func call(_ page: SettingsPageProvider, _ op: String, _ key: String, _ value: CmuxNextSettings.JSONValue? = nil) async throws {
        var params: CmuxNextSettings.JSONValue = ["key": .string(key)]
        if let value, case .object(var members) = params {
            members["value"] = value
            params = .object(members)
        }
        _ = try await page.call("cmux.settings.\(op)", params: params, context: PageCallContext(page: "cmux.settings"))
    }

    @Test func previewRestylesAnExistingLoadingTabBeforeReplying() async throws {
        try await withPage { page, _ in
            var item = TabItem(id: CmuxNextTabs.TabID("loading"), title: "Loading")
            item.indicator = .busy(progress: nil)
            let cell = TabCell(item: item)
            cell.frame = CGRect(x: 0, y: 0, width: 180, height: 28)
            #expect(cell.spinnerLayer?.plan.glyph == .arc)
            try await call(page, "preview", "appearance.statusIndicator.style", .string("dot"))
            #expect(cell.spinnerLayer?.plan.glyph == .dot)
            try await call(page, "preview", "appearance.statusIndicator.thickness", .number(3))
            #expect(cell.spinnerLayer?.glyphLayer?.lineWidth == 3)
            try await call(page, "preview", "appearance.statusIndicator.size", .number(1.5))
            let spinner = try #require(cell.spinnerLayer)
            #expect(spinner.frame.width > 0 && spinner.frame.height > 0)
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
            let script = DesignSettings.shared.interfaceScaleScript(pageZoom: 1.5625)
            #expect(script.contains("--cmux-interface-scale', '\(Typography.userScale)'"))
            #expect(script.contains("--cmux-ui-scale', '1.5625'"))
            #expect(script.contains("cmux-ui-scale-change"))
            let descriptor = try #require(SettingsSchema.descriptor(for: ["appearance", "metrics", "chromeFontSize"]))
            #expect(settings.isCustomized(descriptor))
            try await call(page, "reset", descriptor.id)
            #expect(TypeScale.body == nativeDefault)
            #expect(!settings.isCustomized(descriptor))
            #expect(try await settings.file.value(at: descriptor.path) == nil)
        }
    }

    @Test(.timeLimit(.minutes(1))) func interfaceSizeUpdatesAnExistingFindFieldAndResetsIt() async throws {
        try await withPage { page, _ in
            let image = NSImage(size: NSSize(width: 16, height: 16))
            let pill = FindPillView(
                labels: FindPillLabels(placeholder: "Find", previous: "Previous", next: "Next", close: "Close"),
                icons: FindPillIcons(search: image, previous: image, next: image, close: image),
                accessibilityPrefix: "test.find")
            let original = try #require(pill.field.font).pointSize
            let changes = AsyncStream<CGFloat>.makeStream()
            let field = pill.field
            let fill = field.fill
            // The Swift font override doesn't reliably emit KVO. Its didSet refreshes the
            // themed fill after installing the font, so record that existing render callback.
            field.fill = { [weak field, continuation = changes.continuation] in
                if let size = field?.font?.pointSize { continuation.yield(size) }
                return fill()
            }
            defer { field.fill = fill; changes.continuation.finish() }
            var sizes = changes.stream.makeAsyncIterator()
            try await call(page, "set", "appearance.metrics.chromeFontSize", .number(16))
            // CheckedFont rounds its cache key to hundredths of a point.
            while let size = await sizes.next() { if abs(size - TypeScale.body) < 0.01 { break } }
            let enlarged = try #require(pill.field.font).pointSize
            #expect(abs(enlarged - TypeScale.body) < 0.01)
            #expect(enlarged > original)
            try await call(page, "reset", "appearance.metrics.chromeFontSize")
            while let size = await sizes.next() { if abs(size - original) < 0.01 { break } }
            let restored = try #require(pill.field.font).pointSize
            #expect(abs(restored - original) < 0.01)
        }
    }

    @Test func interfaceSizeScalesFirstRunFontsOnlyOnceAndResetsThem() async throws {
        try await withPage { page, _ in
            let panel = HomeFirstRunView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            panel.starters.setPrompts(["Start a task"])
            let button = try #require(panel.starters.buttons.first)
            let originalButton = try #require(button.font).pointSize
            let labels = [panel.hero.title, panel.hero.body, panel.switchCard.header, panel.switchCard.note, panel.intro.label]
            let originals = try labels.map { try #require($0.font).pointSize }
            try await call(page, "set", "appearance.metrics.chromeFontSize", .number(16))
            // The transcript passes the live interface scale to its first-run panel.
            panel.applyScale(Typography.userScale)
            #expect(abs(try #require(button.font).pointSize - originalButton * Typography.userScale) < 0.01)
            for (label, original) in zip(labels, originals) {
                #expect(abs(try #require(label.font).pointSize - original * Typography.userScale) < 0.01)
            }
            try await call(page, "reset", "appearance.metrics.chromeFontSize")
            panel.applyScale(Typography.userScale)
            #expect(abs(try #require(button.font).pointSize - originalButton) < 0.01)
            for (label, original) in zip(labels, originals) {
                #expect(abs(try #require(label.font).pointSize - original) < 0.01)
            }
        }
    }

    @Test func workingIndicatorToggleAlsoControlsTerminalTitleActivity() async throws {
        try await withPage { page, _ in
            let store = DaemonStore()
            let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "⠐ Working")])
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "test", screens: [screen])]))
            let tab = try #require(store.tab(surface: 1))
            #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").indicator == .working(progress: nil))
            try await call(page, "set", "appearance.statusIndicator.showAgentWorkingOnTabs", .bool(false))
            #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").indicator == .idle)
            try await call(page, "reset", "appearance.statusIndicator.showAgentWorkingOnTabs")
            #expect(TabItemMapping.shared.item(tab, fallbackTitle: "Terminal").indicator == .working(progress: nil))
        }
    }

    @Test func interfaceSizeUpdatesMountedFileNamesWithoutChangingEntriesOrSelection() async throws {
        try await withPage { page, _ in
            let actions = FilesPaneActions(activate: { _ in }, select: { _, _ in }, sort: { _ in },
                                           rename: { _, _ in }, drop: { _, _, _, _ in }, menu: { _ in NSMenu() },
                                           key: { _ in false }, browse: { _ in })
            let icons = FileIconProvider()
            let grid = FileIconGridView(actions: actions, icons: icons)
            let list = FileListView(actions: actions, icons: icons)
            let sidebar = FileSidebarView(actions: FileSidebarActions(open: { _ in }, add: { _, _ in },
                                                                      remove: { _ in }, eject: { _ in }, drop: { _, _, _, _ in }))
            let folder = URL(fileURLWithPath: "/settings-test")
            let entries = [FileEntry(name: "Folder", in: folder, kind: .folder)]
            let selection: Set<String> = ["Folder"]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let root = try #require(window.contentView)
            for (index, view) in [grid.view, list.view, sidebar.view].enumerated() {
                view.frame = NSRect(x: CGFloat(index) * 400, y: 0, width: 400, height: 300)
                root.addSubview(view)
            }
            defer { window.closeAfterTest() }
            window.orderFront(nil)
            let collection = try #require((grid.view as? NSScrollView)?.documentView as? NSCollectionView)
            let table = try #require((list.view as? NSScrollView)?.documentView as? NSTableView)
            let places = try #require((sidebar.view as? NSScrollView)?.documentView as? NSTableView)
            @MainActor func render() {
                grid.show(entries, of: folder, selection: selection)
                list.show(entries, of: folder, selection: selection)
                sidebar.show([.header("Files")], current: folder)
                root.layoutSubtreeIfNeeded()
                collection.layoutSubtreeIfNeeded()
            }
            @MainActor func fonts() throws -> [CGFloat] {
                let tile = try #require(collection.item(at: IndexPath(item: 0, section: 0)))
                let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
                let place = try #require(places.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
                return [try #require(tile.textField?.font).pointSize, try #require(cell.textField?.font).pointSize,
                        try #require(place.textField?.font).pointSize]
            }
            render()
            let originals = try fonts()
            try await call(page, "set", "appearance.metrics.chromeFontSize", .number(16))
            render()
            for (actual, original) in zip(try fonts(), originals) {
                #expect(abs(actual - original * Typography.userScale) < 0.01)
            }
            #expect(collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)])
            #expect(table.selectedRowIndexes == IndexSet(integer: 0))
            try await call(page, "reset", "appearance.metrics.chromeFontSize")
            render()
            for (actual, original) in zip(try fonts(), originals) { #expect(abs(actual - original) < 0.01) }
        }
    }

    @Test func committedControlsApplyWithoutAFileWatcherAndSurviveReload() async throws {
        try await withPage { page, settings in
            let values: [(String, CmuxNextSettings.JSONValue)] = [
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
            #expect(StatusIndicatorAppearance.shared.config.settings == live)
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
