import CmuxNextDesign
import CmuxNextSettings
import Testing

/// u3320: the workspace hover card's layout, its parts and its history length are settings
/// (`sidebar.hoverCards.layout`, `.sections.*`, `.maxRows`): Settings rows, cmux.json, the
/// palette's settings rows and `cmux settings set` all read the same schema rows.
struct HoverCardContentSettingsTests {
    /// The default card is Compact, the facts and the last three moments (Lawrence 2026-11-20: "drastically
    /// simplify all parts of the UI"); Stats and History (u3320) is one setting away.
    @Test func defaultsAreTheCompactCardWithEveryPart() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        let options = snapshot.hoverCards.workspaceCardOptions
        var compact = WorkspaceHoverCardOptions()
        compact.layout = .compact
        #expect(options == compact)
        #expect(options.maxRows == 20)
        let layout = try #require(SettingsSchema.descriptor(for: HoverCardSettings.layoutPath))
        #expect(layout.defaultValue == .string("compact"))
        for path in [HoverCardSettings.timingsPath, HoverCardSettings.promptsPath, HoverCardSettings.waitingPath,
                     HoverCardSettings.gitPath, HoverCardSettings.portsPath] {
            let row = try #require(SettingsSchema.descriptor(for: path), "no Settings row for \(path)")
            #expect(row.kind == .toggle)
            #expect(row.defaultValue == .bool(true))
        }
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.maxRowsPath)?.defaultValue == .number(20))
    }

    @Test func cmuxJSONPicksTheLayoutPartsAndLength() {
        let root = JSONValue.object(["sidebar": .object(["hoverCards": .object([
            "layout": .string("log"),
            "maxRows": .number(7),
            "sections": .object(["git": .bool(false), "prompts": .bool(false), "timings": .bool(false)]),
        ])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        let options = snapshot.hoverCards.workspaceCardOptions
        #expect(options.layout == .log)
        #expect(options.maxRows == 7)
        #expect(!options.showsGit && !options.showsPrompts && !options.showsTimings)
        #expect(options.showsWaiting && options.showsPorts)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test func aBadLayoutKeepsTheDefaultWithADiagnostic() {
        let root = JSONValue.object(["sidebar": .object(["hoverCards": .object(["layout": .string("huge"), "maxRows": .number(500)])])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.workspaceCardOptions.layout == .compact)
        #expect(snapshot.hoverCards.workspaceCardOptions.maxRows == 100)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.hoverCards.layout" })
    }
}
