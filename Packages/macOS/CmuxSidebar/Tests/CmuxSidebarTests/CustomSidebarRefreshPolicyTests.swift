import Foundation
import Testing
@testable import CmuxSidebar

/// Issue #46725: only sidebars that read `clock` may tick every second.
@Suite("CustomSidebarRefreshPolicy")
struct CustomSidebarRefreshPolicyTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CmuxSidebarTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // CmuxSidebar
        .deletingLastPathComponent() // macOS
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()

    private static let templatesDirectory = repoRoot
        .appendingPathComponent("Packages/macOS/CmuxSettings/Sources/CmuxSettings/Resources/CustomSidebarTemplates")

    private func source(_ relativePath: String, in directory: URL = repoRoot) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test func jsClockSignalTicksEverySecond() {
        #expect(CustomSidebarRefreshPolicy.policy(forSource: "Text(() => data.clock()?.time)") == .everySecond)
    }

    @Test func swiftClockKeyTicksEverySecond() {
        #expect(CustomSidebarRefreshPolicy.policy(forSource: "Text(clock.time)") == .everySecond)
    }

    @Test func clockAtTheEdgesOfTheSourceTicksEverySecond() {
        #expect(CustomSidebarRefreshPolicy.sourceReadsClock("clock"))
        #expect(CustomSidebarRefreshPolicy.sourceReadsClock("x = clock"))
        #expect(CustomSidebarRefreshPolicy.sourceReadsClock("clock.epoch"))
    }

    @Test func sidebarWithoutClockRefreshesOnDataChange() {
        let source = """
        sidebar(() => VStack([ForEach({ items: () => data.workspaces() ?? [] }, (w) => Text(() => w().title))]))
        """
        #expect(CustomSidebarRefreshPolicy.policy(forSource: source) == .onDataChange)
    }

    @Test func clockInsideALongerIdentifierDoesNotTick() {
        #expect(!CustomSidebarRefreshPolicy.sourceReadsClock("let clockwise = 1; let unclock = 2; let $clock_ = 3"))
        #expect(!CustomSidebarRefreshPolicy.sourceReadsClock("clock2"))
    }

    @Test func anyCandidateFileReadingClockTicks() {
        #expect(CustomSidebarRefreshPolicy.policy(forSources: ["Text(\"a\")", "Text(clock.time)"]) == .everySecond)
        #expect(CustomSidebarRefreshPolicy.policy(forSources: ["Text(\"a\")"]) == .onDataChange)
        #expect(CustomSidebarRefreshPolicy.policy(forSources: []) == .onDataChange)
    }

    /// The stock template from the issue report must stop ticking.
    @Test func stockWorkspacesTemplateRefreshesOnDataChange() throws {
        let source = try source("workspaces.js", in: Self.templatesDirectory)
        #expect(CustomSidebarRefreshPolicy.policy(forSource: source) == .onDataChange)
    }

    /// Templates that show elapsed times keep their once-a-second tick.
    @Test(arguments: ["agents-board.js", "btop-agents.js", "panel-subagents.js"])
    func clockTemplatesKeepTicking(_ name: String) throws {
        let source = try source(name, in: Self.templatesDirectory)
        #expect(CustomSidebarRefreshPolicy.policy(forSource: source) == .everySecond)
    }

    @Test func clockExampleKeepsTicking() throws {
        let source = try source("Examples/CustomSidebars/clock.swift")
        #expect(CustomSidebarRefreshPolicy.policy(forSource: source) == .everySecond)
    }
}
