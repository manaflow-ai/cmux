import Foundation
import Testing

@testable import CmuxMobileShellUI

@MainActor
@Suite("MobileVoiceMemory")
struct MobileVoiceMemoryTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileVoiceMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("remembers, trims, and persists across instances")
    func rememberPersists() {
        let defaults = makeDefaults()
        let memory = MobileVoiceMemory(defaults: defaults)
        #expect(memory.remember("  My main repo is ~/dev/cmux.  ") == "My main repo is ~/dev/cmux.")
        #expect(memory.remember("   ") == nil)

        let reloaded = MobileVoiceMemory(defaults: defaults)
        #expect(reloaded.entries.map(\.text) == ["My main repo is ~/dev/cmux."])
    }

    @Test("exact duplicates refresh instead of duplicating")
    func duplicates() {
        let memory = MobileVoiceMemory(defaults: makeDefaults())
        memory.remember("Always use codex.")
        memory.remember("Keep replies short.")
        memory.remember("always use CODEX.")
        #expect(memory.entries.map(\.text) == ["Keep replies short.", "always use CODEX."])
    }

    @Test("caps entry length and total count, evicting oldest")
    func caps() {
        let memory = MobileVoiceMemory(defaults: makeDefaults())
        let long = String(repeating: "x", count: MobileVoiceMemory.maximumEntryLength + 50)
        #expect(memory.remember(long)?.count == MobileVoiceMemory.maximumEntryLength)
        for index in 0..<(MobileVoiceMemory.maximumEntries + 10) {
            memory.remember("fact \(index)")
        }
        #expect(memory.entries.count == MobileVoiceMemory.maximumEntries)
        #expect(memory.entries.first?.text == "fact 10")
        #expect(memory.entries.last?.text == "fact \(MobileVoiceMemory.maximumEntries + 9)")
    }

    @Test("forget removes matching entries case-insensitively")
    func forget() {
        let defaults = makeDefaults()
        let memory = MobileVoiceMemory(defaults: defaults)
        memory.remember("My main repo is ~/dev/cmux.")
        memory.remember("Keep replies short.")
        #expect(memory.forget(matching: "MAIN REPO") == 1)
        #expect(memory.forget(matching: "nothing like this") == 0)
        #expect(memory.forget(matching: "  ") == 0)
        let reloaded = MobileVoiceMemory(defaults: defaults)
        #expect(reloaded.entries.map(\.text) == ["Keep replies short."])
    }

    @Test("prompt summary renders bullets and respects the budget")
    func promptSummary() {
        let memory = MobileVoiceMemory(defaults: makeDefaults())
        #expect(memory.promptSummary == nil)
        memory.remember("first")
        memory.remember("second")
        #expect(memory.promptSummary == "- first\n- second")
        for index in 0..<40 {
            memory.remember(String(repeating: "y", count: 100) + " \(index)")
        }
        let summary = memory.promptSummary!
        #expect(summary.count <= MobileVoiceMemory.promptBudgetCharacters)
        // Newest entries survive the budget cut.
        #expect(summary.contains("39"))
        #expect(!summary.contains("- first"))
    }
}
