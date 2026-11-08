import CmuxSettings
import Foundation
import Observation
import Testing

@testable import CmuxSettingsUI

@MainActor
private final class ShortcutListObservationRenderer {
    private let model: ShortcutListModel
    private let action: ShortcutAction
    var rendered: StoredShortcut??

    init(model: ShortcutListModel, action: ShortcutAction) {
        self.model = model
        self.action = action
    }

    func render() {
        withObservationTracking {
            rendered = model.effective(for: action)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.render() }
        }
    }
}

/// Observation regression tests for ``ShortcutListModel``.
@MainActor
@Suite struct ShortcutListModelObservationTests {

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    @Test func failedWriteRollbackInvalidatesPendingRenderGeneration() async throws {
        // WHY: SwiftUI can re-install row tracking while an optimistic write is
        // pending; rollback must invalidate that generation so rows show committed state.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-list-model-observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let blockedParent = tempDir.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedParent)
        let store = JSONConfigStore(fileURL: blockedParent.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let errorLog = SettingsErrorLog()
        let action = ShortcutAction.openSettings
        let shortcut = StoredShortcut(first: ShortcutStroke(
            key: "j", command: true, shift: true, option: true, control: true
        ))
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: errorLog)
        let renderer = ShortcutListObservationRenderer(model: model, action: action)

        renderer.render()
        await model.assign(stroke: shortcut.first, to: action)

        await spin(until: { renderer.rendered == action.defaultShortcut })
        #expect(model.effective(for: action) == action.defaultShortcut)
    }
}
