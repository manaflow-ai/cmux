import Foundation
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Chats under their project folders, each with its age on the right and its branch under the title, as
/// the Codex app, T3 Code and the Claude Code desktop app list them. It is existing settings plus one:
/// `sidebar.groupBy` folder, `sidebar.showTimestamps`, `sidebar.workspaceRow.branch`, and
/// `sidebar.relativeTimestamps` (off by default), which makes a change today read `2h`, not its time.
@MainActor struct SidebarThreadsLookTests {
    static func chat(_ id: String, _ title: String, folder: String, branch: String, age: TimeInterval, now: Date) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: title, directory: folder, branch: branch,
                         lastActivity: now.addingTimeInterval(-age), rowKind: .agent, kind: .terminal, activity: .idle, folder: folder)
    }

    static func sections(now: Date) -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        return [SidebarSection(kind: .machine(machine), nodes: [
            .workspace(chat("a", "Fix the login redirect", folder: "~/src/web", branch: "fix/login", age: 2 * 3_600, now: now)),
            .workspace(chat("b", "Speed up the build", folder: "~/src/api", branch: "perf/build", age: 5 * 60, now: now)),
            .workspace(chat("c", "Write the release notes", folder: "~/src/web", branch: "main", age: 3 * 86_400, now: now)),
        ])]
    }

    /// The settings a profile sets for the look: `sidebar.groupBy` folder, `sidebar.showTimestamps`,
    /// `sidebar.relativeTimestamps` and `sidebar.workspaceRow.branch`.
    static func applyLook(_ preferences: inout SidebarSectionsPreferences) {
        preferences.groupBy = .folder
        (preferences.showTimestamps, preferences.relativeTimestamps) = (true, true)
        preferences.workspaceRow = WorkspaceRowPreferences(base: WorkspaceRowElements(shown: WorkspaceRowElements.standard.shown.union([.branch])))
    }

    static func applyLook(_ model: SidebarModel) {
        var preferences = SidebarSectionsPreferences.defaults
        applyLook(&preferences)
        model.applyListPreferences(preferences)
    }

    private static func layout(_ model: SidebarModel) -> SidebarLayout {
        SidebarLayout.make(sections: model.sections, metrics: .standard, options: model.listOptions())
    }

    @Test func chatsSitUnderTheirProjectFolderWithAnAgeAndABranch() {
        // The layout counts from the current minute: ages from that minute read whole.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let model = SidebarModel(sections: Self.sections(now: now))
        Self.applyLook(model)
        let rows = Self.layout(model).rows
        let order: [String] = rows.compactMap { row -> String? in
            switch row.key {
            case let .folder(_, folder): "folder \(folder)"
            case let .workspace(id): id.rawValue
            default: nil
            }
        }
        #expect(order == ["folder ~/src/web", "a", "c", "folder ~/src/api", "b"])
        var content: [String: WorkspaceRowContent] = [:]
        for row in rows {
            if case let .workspace(id) = row.key, let shown = row.content { content[id.rawValue] = shown }
        }
        #expect(content["a"]?.badgeTime == "2h")
        #expect(["5m", "6m"].contains(content["b"]?.badgeTime ?? ""), "a minute may pass before the layout")
        #expect(content["c"]?.badgeTime == "3d")
        #expect(content["a"]?.detail == "fix/login")
    }

    @Test func todaysChangesKeepTheirTimeByDefault() {
        let now = Date()
        let model = SidebarModel(sections: Self.sections(now: now))
        Self.applyLook(model)
        model.relativeTimestamps = false
        let row = Self.layout(model).rows.first { $0.key == .workspace(WorkspaceID("b")) }
        let expected = now.addingTimeInterval(-5 * 60).formatted(date: .omitted, time: .shortened)
        // A change five minutes ago is today unless the test runs in the day's first five minutes.
        if Calendar.current.isDate(now.addingTimeInterval(-5 * 60), inSameDayAs: now) {
            #expect(row?.content?.badgeTime == expected)
        }
    }

    @Test func relativeAgesCountWholeMinutesThenHours() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ seconds: TimeInterval) -> String {
            WorkspaceRowContent.ageText(now.addingTimeInterval(-seconds), now: now, relative: true)
        }
        #expect(age(10) == "1m")
        #expect(age(59 * 60) == "59m")
        #expect(age(2 * 3_600 + 60) == "2h")
        #expect(!age(2 * 86_400).hasSuffix("h"), "a day or more reads in days, as before")
    }

    @Test func aQuietListReloadsOnlyAsALabelTurns() {
        let now = Date(timeIntervalSince1970: 1_800_000_030) // 30 s past a minute
        // A row five minutes old turns at the next minute, a second past it.
        #expect(SidebarRelativeTimesTick.delay([now.addingTimeInterval(-300)], now: now) == .milliseconds(31_000))
        // A row 2h 10m old reads 2h 9.5m from the floored minute: it turns 3h 51 minutes on, a second past it.
        let hours = SidebarRelativeTimesTick.delay([now.addingTimeInterval(-(2 * 3_600 + 600))], now: now)
        #expect(hours == .milliseconds(51 * 60_000 + 1_000 - 30_000))
        // Rows a day old or more read in days: nothing is scheduled.
        #expect(SidebarRelativeTimesTick.delay([now.addingTimeInterval(-2 * 86_400)], now: now) == nil)
        #expect(SidebarRelativeTimesTick.delay([Date](), now: now) == nil)
    }
}
