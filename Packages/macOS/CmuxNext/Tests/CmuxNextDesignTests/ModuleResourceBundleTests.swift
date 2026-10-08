import CmuxNextDesign
import Foundation
import Testing

/// SwiftPM's generated `Bundle.module` traps when the resource bundle is gone
/// (the app's folder deleted while it runs). `ModuleResourceBundle` returns
/// nil instead and localized text falls back to the English source string.
struct ModuleResourceBundleTests {
    @Test func missingBundleResolvesToNil() {
        let strings = ModuleResourceBundle(
            name: "CmuxNext_Missing",
            searchDirectories: [URL(fileURLWithPath: "/nonexistent-cmux-next-\(UUID().uuidString)")]
        )
        #expect(strings.bundle == nil)
    }

    @Test func missingBundleTextIsTheEnglishSource() {
        let strings = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: [])
        #expect(strings.text("test.plain", defaultValue: "Process exited") == "Process exited")
        let count = 3
        #expect(strings.text("test.interpolated", defaultValue: "\(count) tabs") == "3 tabs")
    }

    @Test func bundleInASearchDirectoryIsFound() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "module-resource-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder.appending(path: "CmuxNext_Present.bundle", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        let strings = ModuleResourceBundle(
            name: "CmuxNext_Present",
            searchDirectories: [URL(fileURLWithPath: "/nonexistent-cmux-next"), folder]
        )
        #expect(strings.bundle?.bundleURL.lastPathComponent == "CmuxNext_Present.bundle")
    }
}

extension ModuleResourceBundleTests {
    @Test func missingLocalizationFallsBackToEnglish() {
        let strings = ModuleResourceBundle(name: "CmuxNext_Missing", searchDirectories: []).localization("de")
        #expect(strings.bundle == nil)
        #expect(strings.text("test.plain", defaultValue: "Process exited") == "Process exited")
    }
}
