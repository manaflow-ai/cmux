import Testing

@testable import CmuxCommandPalette

@Suite("CommandPaletteCommandListBuildPlan")
struct CommandPaletteCommandListBuildPlanTests {
    private func contribution(
        _ id: String,
        title: String,
        keywords: [String] = [],
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: id,
            title: { _ in title },
            subtitle: { _ in "sub-\(id)" },
            keywords: keywords,
            when: when,
            enablement: enablement
        )
    }

    @Test("ranks survivors monotonically and resolves handlers")
    func ranksSurvivors() {
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [
                contribution("a", title: "A"),
                contribution("b", title: "B"),
            ],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { _ in nil },
            resolveShortcutHint: { _, _ in nil },
            resolveHandler: { _ in {} },
            onMissingHandler: { _ in Issue.record("unexpected missing handler") }
        )
        #expect(plan.commands.map(\.id) == ["a", "b"])
        #expect(plan.commands.map(\.rank) == [0, 1])
        #expect(plan.commands.map(\.title) == ["A", "B"])
    }

    @Test("when/enablement gates filter and ranks skip the filtered command")
    func gatingFilters() {
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [
                contribution("a", title: "A", when: { _ in false }),
                contribution("b", title: "B", enablement: { _ in false }),
                contribution("c", title: "C"),
            ],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { _ in nil },
            resolveShortcutHint: { _, _ in nil },
            resolveHandler: { _ in {} },
            onMissingHandler: { _ in Issue.record("unexpected missing handler") }
        )
        #expect(plan.commands.map(\.id) == ["c"])
        #expect(plan.commands.map(\.rank) == [0])
    }

    @Test("config override with palette=false removes the command")
    func paletteHiddenOverrideRemoves() {
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [contribution("a", title: "A"), contribution("b", title: "B")],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { id in
                id == "a"
                    ? CommandPaletteConfigActionOverride(palette: false, title: "x", subtitle: nil, keywords: [])
                    : nil
            },
            resolveShortcutHint: { _, _ in nil },
            resolveHandler: { _ in {} },
            onMissingHandler: { _ in Issue.record("unexpected missing handler") }
        )
        #expect(plan.commands.map(\.id) == ["b"])
    }

    @Test("config override prefers title/subtitle and non-empty keywords")
    func overrideMerge() {
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [
                contribution("withKW", title: "BaseT", keywords: ["base"]),
                contribution("noKW", title: "BaseT2", keywords: ["base2"]),
                contribution("nilSub", title: "BaseT3", keywords: ["base3"]),
            ],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { id in
                switch id {
                case "withKW":
                    return CommandPaletteConfigActionOverride(palette: true, title: "OverT", subtitle: "OverS", keywords: ["over"])
                case "noKW":
                    return CommandPaletteConfigActionOverride(palette: true, title: "OverT2", subtitle: "OverS2", keywords: [])
                case "nilSub":
                    return CommandPaletteConfigActionOverride(palette: true, title: "OverT3", subtitle: nil, keywords: ["over3"])
                default:
                    return nil
                }
            },
            resolveShortcutHint: { _, _ in nil },
            resolveHandler: { _ in {} },
            onMissingHandler: { _ in Issue.record("unexpected missing handler") }
        )
        // Override keywords win when non-empty.
        #expect(plan.commands[0].title == "OverT")
        #expect(plan.commands[0].subtitle == "OverS")
        #expect(plan.commands[0].keywords == ["over"])
        // Empty override keywords fall back to the contribution keywords.
        #expect(plan.commands[1].keywords == ["base2"])
        // Nil override subtitle falls back to the contribution subtitle.
        #expect(plan.commands[2].subtitle == "sub-nilSub")
        #expect(plan.commands[2].title == "OverT3")
    }

    @Test("missing handler reports the id and skips the command")
    func missingHandler() {
        var missing: [String] = []
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [contribution("a", title: "A"), contribution("b", title: "B")],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { _ in nil },
            resolveShortcutHint: { _, _ in nil },
            resolveHandler: { $0 == "a" ? nil : {} },
            onMissingHandler: { missing.append($0) }
        )
        #expect(missing == ["a"])
        #expect(plan.commands.map(\.id) == ["b"])
        #expect(plan.commands.map(\.rank) == [0])
    }

    @Test("shortcut hint resolver feeds the command")
    func shortcutHint() {
        let plan = CommandPaletteCommandListBuildPlan(
            contributions: [contribution("a", title: "A")],
            context: CommandPaletteContextSnapshot(),
            resolveConfigOverride: { _ in nil },
            resolveShortcutHint: { contribution, _ in "HINT-\(contribution.commandId)" },
            resolveHandler: { _ in {} },
            onMissingHandler: { _ in Issue.record("unexpected missing handler") }
        )
        #expect(plan.commands.first?.shortcutHint == "HINT-a")
    }
}
