import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Every palette action that writes a cmux.json key the settings schema
/// lists goes through the validated `setSetting` path (the one the
/// Settings window uses), not a raw path write: focus ring, strip
/// scrollbar and notification dismissal used to write raw paths with no
/// schema check. Each row runs the action through the registry, awaits the
/// write it reports (`ActionRegistry.track`) and checks that the key was
/// written once through `setSetting` with a value its descriptor accepts.
@MainActor @Suite(.serialized) struct SettingsActionWritePathTests {
    /// Action, then the schema key it writes.
    static let table: [(ActionID, String)] = [
        ("appearance.density.comfortable", "appearance.density"),
        ("appearance.density.compact", "appearance.density"),
        ("appearance.animationSpeed.normal", "ui.animationSpeed"),
        ("layout.centerFocusedColumn.always", "layout.centerFocusedColumn"),
        ("appearance.interfaceSize.increase", "appearance.metrics.chromeFontSize"),
        ("appearance.interfaceSize.decrease", "appearance.metrics.chromeFontSize"),
        ("appearance.interfaceSize.reset", "appearance.metrics.chromeFontSize"),
        ("appearance.paneBorder.toggle", "layout.paneBorder"),
        ("appearance.panePadding.toggle", "layout.panePadding"),
        ("appearance.paneCorners.toggle", "layout.paneCornerRadius"),
        ("appearance.paneBorderWidth.toggle", "layout.paneBorderWidth"),
        ("appearance.paneBorderColor.reset", "layout.paneBorderColor"),
        ("appearance.titlebar.standard", "window.titlebar"),
        ("appearance.titlebar.minimal", "window.titlebar"),
        ("focusRing.toggle", "focusRing.enabled"),
        ("focusRing.style.glow", "focusRing.style"),
        ("focusRing.singlePane.toggle", "focusRing.showWhenSinglePane"),
        ("layout.toggleStripScrollbar", "layout.stripScrollbar"),
        ("notifications.toggleBanners", "notifications.desktop"),
        ("notifications.dismissal.focus", "notifications.dismissal"),
    ]

    @Test func everySchemaKeyAPaletteActionWritesGoesThroughSetSetting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-action-write-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url)
        services.settings = settings
        await settings.reload()
        // A design of its own: the handlers apply each value live first,
        // and other suites read the shared one in parallel.
        let design = DesignSettings()
        let context = AppActionContext(services: services, design: design)
        AppearanceHandlers.bind(into: registry, context: context)
        FocusRingHandlers.bind(into: registry, context: context)
        NotificationSettingsHandlers.bind(into: registry, context: context)
        StickyColumnHandlers.bind(into: registry, context: context)

        for (action, key) in Self.table {
            let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigFile.keyPath(from: key)), "\(key) is not a schema key")
            let before = settings.validatedWrites[key, default: 0]
            let work = registry.capturingWork { _ = registry.perform(action) }
            #expect(!work.isEmpty, "\(action.rawValue) reported no write")
            for task in work {
                let failure = await task.value
                #expect(failure == nil, "\(action.rawValue): \(String(describing: failure))")
            }
            #expect(settings.validatedWrites[key, default: 0] > before, "\(action.rawValue) wrote \(key) without setSetting")
            let root = try JSONC.parse(String(contentsOf: url, encoding: .utf8))
            if let value = root.value(at: descriptor.path) {
                #expect(descriptor.accepts(value), "\(action.rawValue) wrote \(key) = \(value.compactText)")
            }
        }
        // The live values landed on the context's design: each of these
        // differs from a fresh DesignSettings.
        #expect(design.animationSpeed == .normal)
        #expect(design.centerFocusedColumn == .always)
        #expect(design.focusRing.style == .glow)
    }
}
