import CmuxNextResources
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// The detector for a readout that shows blank or a placeholder for a live session (hq docs/handbook
/// `blank-readout-for-live-session.md`). Leo 2026-11-27, ask-3729c9c563: "ok why dont your tabs have any
/// names/letters showing up? that intentional? also the memory line... it should be the ram usage. why
/// dont we have ram usage?" Each readout that renders from a session's records and samples (the tab
/// card's title, place, status and memory rows, the workspace card's resource line, a Task Manager row)
/// is computed for a fixture live, measured session and must hold a value; and a sample that measured
/// nothing reads as the dash, never as a number that looks real ("Zero KB", "0.0%").
@MainActor
struct ReadoutPlaceholderTests {
    /// Text a readout shows when it has no value: empty, a dash, a zero number, or the untitled name.
    static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == CmuxNextTabs.Strings.untitled { return true }
        let markers = ["–", "—", "Zero ", "0.0%", "(null)"]
        return markers.contains { trimmed.contains($0) }
    }

    private static let tabID = "live-agent-chat"
    private static let usage = ResourceUsage(cpu: 0.12, memoryBytes: 412 << 20)

    /// One measured sample of the live chat's processes.
    private static func measured(_ usage: ResourceUsage = usage) -> ResourceReport {
        ResourceReport(tabs: [TabResourceReport(id: tabID, title: "Fix the login bug", kind: .webkit, usage: usage,
                                                processCount: 3, sharedWithTabs: 0, available: true)],
                       total: usage, processCount: 3)
    }

    /// A live agent chat as the strip maps it: titled, in a folder, working with a model.
    private static func liveChat() -> TabItem {
        var item = TabItem(id: TabID(tabID), title: "Fix the login bug", subtitle: "~/Projects/site")
        item.hover = TabHoverFacts(kind: .agentChat, activity: .working, since: Date().addingTimeInterval(-90), model: "Opus 5.5")
        return item
    }

    @Test func aLiveMeasuredChatsTabCardHasNoPlaceholderRow() {
        let lines = TabHoverCardLines.make(Self.liveChat(), report: Self.measured(), now: Date())
        let named: [(String, String?)] = [("title", lines.title), ("place", lines.place), ("status", lines.status), ("memory", lines.memory)]
        for (field, value) in named {
            let text = value ?? ""
            #expect(!Self.isPlaceholder(text), "the tab card's \(field) row reads \"\(text)\" for a live, measured chat")
        }
        #expect(lines.memory == "Memory \(ResourceFormat.memory(412 << 20))", "the chat's RAM: \(String(describing: lines.memory))")
    }

    @Test func aLiveMeasuredWorkspacesResourceLineHasNoPlaceholder() {
        let line = WorkspaceHoverCardContent.resourceLine(Self.measured()) ?? ""
        #expect(!Self.isPlaceholder(line), "the workspace card's resource line reads \"\(line)\" for a measured workspace")
    }

    @Test func aLiveTaskManagerRowHasNoPlaceholder() {
        let row = TaskManagerRow(id: ProcessKey(pid: 4242), kind: .app, task: "cmux", name: "cmux", cpu: 0.05, memoryBytes: 96 << 20)
        #expect(!Self.isPlaceholder(row.memoryText), "Memory column: \(row.memoryText)")
        #expect(!Self.isPlaceholder(row.cpuText), "CPU column: \(row.cpuText)")
    }

    /// A sample that measured processes but read zero bytes (a remote daemon that could not read its
    /// tree) is no reading: the dash, never "Memory Zero KB" or a CPU beside it.
    @Test func aZeroByteSampleReadsAsTheDashNotZero() {
        let zero = ResourceUsage(cpu: 0.8, memoryBytes: 0)
        let lines = TabHoverCardLines.make(Self.liveChat(), report: Self.measured(zero), now: Date())
        #expect(lines.memory == "Memory –", "a zero-byte read: \(String(describing: lines.memory))")
        #expect(ResourceFormat.memory(0) == "–")
        #expect(ResourceFormat.line(ResourceUsage(cpu: 0, memoryBytes: 0)) == "CPU – · Memory –")
        #expect(ResourceFormat.compact(ResourceUsage(cpu: 0, memoryBytes: 0)) == "– · –")
        let row = TaskManagerRow(id: ProcessKey(pid: 4243), kind: .app, task: "cmux", name: "cmux", cpu: nil, memoryBytes: 0)
        #expect(row.memoryText == "–", "Memory column of an unread process: \(row.memoryText)")
    }

    /// The detector itself: it flags each placeholder shape and passes real values.
    @Test func theDetectorTellsPlaceholdersFromValues() {
        for text in ["", " ", "–", "Memory –", "Memory Zero KB", "CPU 0.0% · Memory 12 MB", CmuxNextTabs.Strings.untitled] {
            #expect(Self.isPlaceholder(text), "\"\(text)\" passed as a value")
        }
        for text in ["Fix the login bug", "Memory 412 MB", "Working · 1m · Opus 5.5", "~/Projects/site", "CPU 12.0% · Memory 412 MB"] {
            #expect(!Self.isPlaceholder(text), "\"\(text)\" flagged as a placeholder")
        }
    }
}
