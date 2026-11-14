import CmuxNextSettings
import Testing

/// Settings > Chief > Subagents (a1018): the four rows the Chief host reads at each spawn to decide which
/// subagents get a sidebar workspace. Their keys must match what optchat-chief `sidebar_choice.rs` reads,
/// their defaults must match its defaults, and only the person may change them.
struct ChiefSidebarSettingsTests {
    static let paths: [[String]] = [
        ["chief", "subagentSidebar"],
        ["chief", "subagentSidebarShowWords"],
        ["chief", "subagentSidebarHideWords"],
        ["chief", "subagentSidebarMinWords"],
    ]

    @Test func theFourRowsShowInOneGroupInTheirOrder() throws {
        let rows = try Self.paths.map { try #require(SettingsSchema.descriptor(for: $0), "a row for \($0)") }
        #expect(Set(rows.map(\.section)).count == 1)
        #expect(Set(rows.map(\.group)).count == 1, "one group, Subagents")
        let shown = SettingsSchema.settings(in: rows[0].section).filter { Self.paths.contains($0.path) }.map(\.path)
        #expect(shown == Self.paths, "Settings lists them together, mode first")
        for row in rows { #expect(!row.title.isEmpty && row.help?.isEmpty == false, "\(row.id) has a title and help") }
    }

    @Test func modeChoosesAutoAlwaysOrNeverAndDefaultsToAuto() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.paths[0]))
        guard case .choice(let choices) = row.kind else { Issue.record("mode is a choice, got \(row.kind)"); return }
        #expect(choices.map(\.value) == ["auto", "always", "never"])
        #expect(row.defaultValue == .string("auto"))
    }

    @Test func wordListsAreEmptyStringLists() throws {
        for path in Self.paths[1...2] {
            let row = try #require(SettingsSchema.descriptor(for: path))
            #expect(row.kind == .stringList, "\(row.id)")
            #expect(row.defaultValue == .array([]), "the built-in words live in the Chief host")
        }
    }

    @Test func minWordsIsACountDefaultingToFifty() throws {
        let row = try #require(SettingsSchema.descriptor(for: Self.paths[3]))
        guard case .number(let number) = row.kind else { Issue.record("min words is a number, got \(row.kind)"); return }
        #expect(number.unit == .count)
        #expect(number.range == 0...1000)
        #expect(row.defaultValue == .number(50), "matches sidebar_choice.rs DEFAULT_MIN_WORDS")
    }

    @Test func onlyThePersonChangesThem() throws {
        for path in Self.paths {
            let row = try #require(SettingsSchema.descriptor(for: path))
            #expect(SettingsSchema.agentSettable(row) == false, "\(row.id)")
            #expect(SettingsSchema.agentRefusedKeys[row.id] == .userOnly, "\(row.id)")
        }
    }
}
