import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

@MainActor @Suite(.serialized) struct TerminalFontPersistenceTests {
    @Test func anOlderOnDiskSettingsFileKeepsTheChosenFamilyAndSizeAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "terminal-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux-next.json")
        try Data(#"{ "terminal": { "fontFamily": "Iosevka Term", "fontSize": 17 } }"#.utf8).write(to: url)

        let settings = SettingsController(registry: .standard(), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        #expect(settings.snapshot.terminalFontFamily == "Iosevka Term")
        #expect(settings.snapshot.terminalFontSize == 17)
        #expect(settings.fileRoot.value(at: ["terminal", "fontFamily"]) == .string("Iosevka Term"))
        #expect(settings.fileRoot.value(at: ["terminal", "fontSize"]) == .number(17))
    }
}
