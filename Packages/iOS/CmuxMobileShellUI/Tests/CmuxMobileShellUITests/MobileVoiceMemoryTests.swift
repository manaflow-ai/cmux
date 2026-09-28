import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite("MobileVoiceMemory")
struct MobileVoiceMemoryTests {
    private func makeFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileVoiceMemoryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("memories.json")
    }

    @Test("remembers, trims, and persists to disk across instances")
    func rememberPersists() {
        let fileURL = makeFileURL()
        let memory = MobileVoiceMemory(fileURL: fileURL, migratingFrom: nil)
        #expect(memory.remember("  My main repo is ~/dev/cmux.  ") == "My main repo is ~/dev/cmux.")
        #expect(memory.remember("   ") == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = MobileVoiceMemory(fileURL: fileURL, migratingFrom: nil)
        #expect(reloaded.entries.map(\.text) == ["My main repo is ~/dev/cmux."])
    }

    @Test("migrates a legacy UserDefaults store once, then removes it")
    func migratesLegacyDefaults() throws {
        let suiteName = "MobileVoiceMemoryTests-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let legacy = [MobileVoiceMemory.Entry(text: "carried over")]
        defaults.set(try JSONEncoder().encode(legacy), forKey: "cmux.mobile.voice.memories")

        let fileURL = makeFileURL()
        let memory = MobileVoiceMemory(fileURL: fileURL, migratingFrom: defaults)
        #expect(memory.entries.map(\.text) == ["carried over"])
        #expect(defaults.data(forKey: "cmux.mobile.voice.memories") == nil)
        // The file now owns the data; a re-open without defaults still has it.
        let reloaded = MobileVoiceMemory(fileURL: fileURL, migratingFrom: nil)
        #expect(reloaded.entries.map(\.text) == ["carried over"])
    }

    @Test("exact duplicates refresh instead of duplicating")
    func duplicates() {
        let memory = MobileVoiceMemory(fileURL: makeFileURL(), migratingFrom: nil)
        memory.remember("Always use codex.")
        memory.remember("Keep replies short.")
        memory.remember("always use CODEX.")
        #expect(memory.entries.map(\.text) == ["Keep replies short.", "always use CODEX."])
    }

    @Test("caps entry length")
    func capsEntryLength() {
        let memory = MobileVoiceMemory(fileURL: makeFileURL(), migratingFrom: nil)
        let long = String(repeating: "x", count: MobileVoiceMemory.maximumEntryLength + 50)
        #expect(memory.remember(long)?.count == MobileVoiceMemory.maximumEntryLength)
    }

    @Test("forget removes matching entries case-insensitively")
    func forget() {
        let fileURL = makeFileURL()
        let memory = MobileVoiceMemory(fileURL: fileURL, migratingFrom: nil)
        memory.remember("My main repo is ~/dev/cmux.")
        memory.remember("Keep replies short.")
        #expect(memory.forget(matching: "MAIN REPO") == 1)
        #expect(memory.forget(matching: "nothing like this") == 0)
        #expect(memory.forget(matching: "  ") == 0)
        let reloaded = MobileVoiceMemory(fileURL: fileURL, migratingFrom: nil)
        #expect(reloaded.entries.map(\.text) == ["Keep replies short."])
    }

    @Test("prompt summary renders bullets and respects its budget")
    func promptSummary() {
        let memory = MobileVoiceMemory(fileURL: makeFileURL(), migratingFrom: nil)
        #expect(memory.promptSummary == nil)
        memory.remember("first")
        memory.remember("second")
        #expect(memory.promptSummary == "- first\n- second")
        for index in 0..<40 {
            memory.remember(String(repeating: "y", count: 100) + " \(index)")
        }
        let summary = memory.promptSummary!
        #expect(summary.count <= MobileVoiceMemory.promptBudgetCharacters)
        // Newest entries survive the budget cut; the tool listing sees more.
        #expect(summary.contains("39"))
        #expect(!summary.contains("- first"))
        let toolListing = memory.toolListSummary!
        #expect(toolListing.count > summary.count)
        #expect(toolListing.contains("- first"))
    }
}
