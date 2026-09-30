@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// End Sessions, Keep Layout writes each tab's directory before the daemon
/// stops; the next launch reads it once to restart the shells.
struct KeptLayoutPlanFileTests {
    @Test func thePlanSurvivesTheRelaunchAndIsForgotten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-kept-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = KeptLayoutPlanFile(url: directory.appending(path: "kept-layout.json"))
        #expect(file.read() == nil)
        let plan = KeptLayoutPlan(tabs: ["tab_a": .init(cwd: "/repo"), "tab_b": .init(cwd: nil)])
        file.write(plan)
        #expect(file.read() == plan)
        file.remove()
        #expect(file.read() == nil)
    }
}
