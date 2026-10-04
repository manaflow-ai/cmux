import CmuxNextApps
import Foundation
import Testing
@testable import CmuxNextApp

/// R134: the Hide App / Show Hidden Apps picker lists installed apps with
/// their state, and a hidden app still opens from the palette.
@MainActor
@Suite struct AppVisibilityPaletteTests {
    private func registry() async throws -> AppRegistry {
        let root = FileManager.default.temporaryDirectory.appending(path: "cmux-app-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = AppRegistry(directory: root, bundledRoot: root.appending(path: "no-samples"))
        await registry.load()
        return registry
    }

    @Test func thePickerListsHiddenAppsFirstWhenShowing() async throws {
        let registry = try await registry()
        let showing = AppVisibilityPalette.apps(registry, hiddenFirst: true)
        #expect(showing.first?.isHidden == true)  // CodeRouter ships hidden
        #expect(showing.contains { $0.id == "cmux/coderouter" })
        let hiding = AppVisibilityPalette.apps(registry, hiddenFirst: false)
        #expect(hiding.first?.isHidden == false)
        #expect(Set(showing.map(\.id)) == Set(hiding.map(\.id)))
    }

    @Test func aHiddenAppStillOpens() async throws {
        let registry = try await registry()
        let coderouter = try #require(registry.app("cmux/coderouter"))
        #expect(coderouter.isHidden)
        #expect(AppPanePage.opens(coderouter))
    }
}
