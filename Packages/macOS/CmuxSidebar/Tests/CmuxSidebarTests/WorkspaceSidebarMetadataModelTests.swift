import Combine
import Foundation
import Testing

@testable import CmuxSidebar

private struct FixedLogLimitProvider: SidebarLogEntryLimitProviding {
    let configuredMaxSidebarLogEntries: Int?
}

@MainActor
@Suite struct WorkspaceSidebarMetadataModelTests {
    private func makeModel(limit: Int? = nil) -> WorkspaceSidebarMetadataModel {
        WorkspaceSidebarMetadataModel(limitProvider: FixedLogLimitProvider(configuredMaxSidebarLogEntries: limit))
    }

    @Test func addStatusEntryKeysByEntryKey() {
        let model = makeModel()
        let entry = SidebarStatusEntry(
            key: "agent",
            value: "running",
            icon: nil,
            color: nil,
            url: nil,
            priority: 1,
            format: .plain,
            timestamp: Date(timeIntervalSince1970: 1)
        )
        model.addStatusEntry(entry)
        #expect(model.statusEntries["agent"] == entry)
    }

    @Test func appendLogEntryTrimsAndDropsEmpty() {
        let model = makeModel()
        model.appendLogEntry(message: "   ", level: .info, source: nil)
        #expect(model.logEntries.isEmpty)
        model.appendLogEntry(message: "  hello  ", level: .info, source: "src")
        #expect(model.logEntries.count == 1)
        #expect(model.logEntries[0].message == "hello")
        #expect(model.logEntries[0].source == "src")
    }

    @Test func appendLogEntryDefaultsToFiftyWhenUnset() {
        let model = makeModel(limit: nil)
        for index in 0..<60 {
            model.appendLogEntry(message: "m\(index)", level: .info, source: nil)
        }
        #expect(model.logEntries.count == 50)
        // Oldest entries trimmed: the buffer keeps the most recent 50.
        #expect(model.logEntries.first?.message == "m10")
        #expect(model.logEntries.last?.message == "m59")
    }

    @Test func appendLogEntryClampsLimitToOne() {
        let model = makeModel(limit: 0)
        model.appendLogEntry(message: "a", level: .info, source: nil)
        model.appendLogEntry(message: "b", level: .info, source: nil)
        #expect(model.logEntries.count == 1)
        #expect(model.logEntries.last?.message == "b")
    }

    @Test func appendLogEntryClampsLimitToFiveHundred() {
        let model = makeModel(limit: 100_000)
        for index in 0..<600 {
            model.appendLogEntry(message: "m\(index)", level: .info, source: nil)
        }
        #expect(model.logEntries.count == 500)
    }

    @Test func metadataBlocksInDisplayOrderSortsByPriorityTimestampKey() {
        let model = makeModel()
        let low = SidebarMetadataBlock(key: "b", markdown: "x", priority: 1, timestamp: Date(timeIntervalSince1970: 10))
        let highOld = SidebarMetadataBlock(key: "a", markdown: "y", priority: 5, timestamp: Date(timeIntervalSince1970: 1))
        let highNew = SidebarMetadataBlock(key: "c", markdown: "z", priority: 5, timestamp: Date(timeIntervalSince1970: 9))
        model.metadataBlocks = ["b": low, "a": highOld, "c": highNew]
        let ordered = model.metadataBlocksInDisplayOrder()
        #expect(ordered.map(\.key) == ["c", "a", "b"])
    }

    @Test func statusEntriesInDisplayOrderSortsByPriorityTimestampKey() {
        let model = makeModel()
        let low = SidebarStatusEntry(
            key: "b", value: "x", priority: 1, timestamp: Date(timeIntervalSince1970: 10)
        )
        let highOld = SidebarStatusEntry(
            key: "a", value: "y", priority: 5, timestamp: Date(timeIntervalSince1970: 1)
        )
        let highNew = SidebarStatusEntry(
            key: "c", value: "z", priority: 5, timestamp: Date(timeIntervalSince1970: 9)
        )
        let ordered = model.statusEntriesInDisplayOrder([low, highOld, highNew])
        #expect(ordered.map(\.key) == ["c", "a", "b"])
    }

    @Test func progressGitAndPullRequestUpdaters() {
        let model = makeModel()
        model.updateProgress(SidebarProgressState(value: 0.5, label: "half"))
        #expect(model.progress?.label == "half")
        model.updateProgress(nil)
        #expect(model.progress == nil)

        model.updateGitBranch(SidebarGitBranchState(branch: "main", isDirty: true))
        #expect(model.gitBranch?.branch == "main")
        #expect(model.gitBranch?.isDirty == true)

        let pr = SidebarPullRequestState(
            number: 7,
            label: "PR 7",
            url: URL(string: "https://example.com/7")!,
            status: .open,
            branch: "feat",
            isStale: false
        )
        model.updatePullRequest(pr)
        #expect(model.pullRequest?.number == 7)
    }

    @Test func publisherSeedsCurrentValueThenEmitsChanges() {
        let model = makeModel()
        var received: [Int] = []
        let cancellable = model.statusEntriesPublisher
            .map(\.count)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // Seeds with the current (empty) value immediately.
        #expect(received == [0])

        model.addStatusEntry(
            SidebarStatusEntry(
                key: "k",
                value: "v",
                icon: nil,
                color: nil,
                url: nil,
                priority: 0,
                format: .plain,
                timestamp: Date(timeIntervalSince1970: 1)
            )
        )
        #expect(received == [0, 1])
    }

    @Test func resetClearsEverySidebarMetadataField() {
        let model = makeModel()
        let id = UUID()
        model.addStatusEntry(
            SidebarStatusEntry(
                key: "agent",
                value: "running",
                icon: nil,
                color: nil,
                url: nil,
                priority: 1,
                format: .plain,
                timestamp: Date(timeIntervalSince1970: 1)
            )
        )
        model.appendLogEntry(message: "hello", level: .info, source: nil)
        model.updateProgress(SidebarProgressState(value: 0.5, label: "half"))
        model.updateGitBranch(SidebarGitBranchState(branch: "main", isDirty: true))
        model.panelGitBranches[id] = SidebarGitBranchState(branch: "dev", isDirty: false)
        let pr = SidebarPullRequestState(
            number: 7,
            label: "PR 7",
            url: URL(string: "https://example.com/7")!,
            status: .open,
            branch: "feat",
            isStale: false
        )
        model.updatePullRequest(pr)
        model.panelPullRequests[id] = pr
        model.metadataBlocks["b"] = SidebarMetadataBlock(
            key: "b", markdown: "x", priority: 1, timestamp: Date(timeIntervalSince1970: 10)
        )

        model.reset()

        #expect(model.statusEntries.isEmpty)
        #expect(model.logEntries.isEmpty)
        #expect(model.progress == nil)
        #expect(model.gitBranch == nil)
        #expect(model.panelGitBranches.isEmpty)
        #expect(model.pullRequest == nil)
        #expect(model.panelPullRequests.isEmpty)
        #expect(model.metadataBlocks.isEmpty)
    }

    @Test func panelMapsForwardThroughStoredProperties() {
        let model = makeModel()
        let id = UUID()
        model.panelGitBranches[id] = SidebarGitBranchState(branch: "dev", isDirty: false)
        #expect(model.panelGitBranches[id]?.branch == "dev")
        model.panelGitBranches.removeValue(forKey: id)
        #expect(model.panelGitBranches[id] == nil)
    }

    @Test func panelDirectoryDisplayLabelsStoreAndPublish() {
        let model = makeModel()
        let id = UUID()
        var emitted: [[UUID: String]] = []
        var cancellables: Set<AnyCancellable> = []
        model.panelDirectoryDisplayLabelsPublisher
            .sink { emitted.append($0) }
            .store(in: &cancellables)
        #expect(emitted == [[:]])

        model.panelDirectoryDisplayLabels[id] = "MyPackage  mainline"
        #expect(model.panelDirectoryDisplayLabels[id] == "MyPackage  mainline")
        model.panelDirectoryDisplayLabels.removeValue(forKey: id)
        #expect(model.panelDirectoryDisplayLabels[id] == nil)
        #expect(emitted.count == 3)
        #expect(emitted.last == [:])
    }
}
