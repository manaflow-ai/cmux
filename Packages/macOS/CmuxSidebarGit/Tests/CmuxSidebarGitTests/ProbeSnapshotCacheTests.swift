import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeSnapshotCacheTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    private func waitUntil(maxYields: Int = 5_000, _ predicate: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitRefreshBypassesTrackedSnapshotCacheGeneration() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "manualRefresh"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
        let advancedGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        #expect(advancedGeneration != initialGeneration)
    }

    @Test(.timeLimit(.minutes(1)))
    func branchChangeBypassesTrackedSnapshotCacheGeneration() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "branchChange"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: ["directoryChange", "branchCleared", "unexpectedReason"]
    )
    func nonWatcherRefreshReasonsBypassTrackedSnapshotCacheGeneration(reason: String) async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(generations == [nil])
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteDirectoryProvenanceBeforeDelayedAttemptDoesNotReadLocalGitMetadata() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "main"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "remoteProvenance"
        )
        await clock.waitForSleeper()
        host.useRemoteDirectoryProvenance(workspaceId: workspaceId, panelId: panelId)
        await clock.resumeNext()

        #expect(await waitUntil { service.workspaceGitProbeStateByKey[key] == nil })
        #expect(await reader.probedDirectories.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func changedDirectoryBeforeDelayedAttemptDoesNotReadLocalGitMetadata() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "main"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "directoryChange"
        )
        await clock.waitForSleeper()
        host.setPanelDirectory(workspaceId: workspaceId, panelId: panelId, directory: "/tmp/other-repo")
        await clock.resumeNext()

        #expect(await waitUntil { service.workspaceGitProbeStateByKey[key] == nil })
        #expect(await reader.probedDirectories.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func filesystemEventGenerationIsPassedToMetadataReader() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "feature/x"))
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[key] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        let eventGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        #expect(eventGeneration != initialGeneration)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        let generations = await reader.probedTrackedPathEventGenerations
        let generation = try #require(generations.first ?? nil)
        #expect(generations.count == 1)
        #expect(generation.namespace == service.workspaceGitSnapshotCacheNamespace)
        #expect(generation.generation == eventGeneration)
    }

    @Test func reusedWatcherMovesCacheGenerationToNewDirectory() throws {
        let oldDirectory = "/tmp/repo"
        let newDirectory = "/tmp/repo/nested"
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: oldDirectory)
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(oldDirectory, for: key)
        service.markWorkspaceGitSnapshotCacheEligible(directory: oldDirectory)
        let oldGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: oldDirectory))

        service.moveWorkspaceGitSnapshotCacheEligibility(for: key, to: newDirectory)
        let newGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: newDirectory))

        #expect(service.workspaceGitSnapshotCacheGeneration(directory: oldDirectory) == nil)
        #expect(newGeneration != oldGeneration)
        service.recordWorkspaceGitMetadataFilesystemEvent(for: key)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: newDirectory) != newGeneration)
    }

    @Test func sharedWatcherDirectoryKeepsCacheEligibilityUntilLastWatcherStops() throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let generation = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.stopWorkspaceGitMetadataWatcher(for: firstKey)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: directory) == generation)
        service.stopWorkspaceGitMetadataWatcher(for: secondKey)
        #expect(service.workspaceGitSnapshotCacheGeneration(directory: directory) == nil)
    }

    @Test func sharedWatchedPathsEventBumpsDirectoryGenerationOnce() throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: ["/tmp/repo/.git/index"])
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: secondKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: firstKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let initialGeneration = service.workspaceGitMetadataFilesystemEventGeneration

        let refreshedKeys = service.recordWorkspaceGitMetadataFilesystemEvent(
            forWatchedPathsKey: watchedPathsKey
        )

        #expect(Set(refreshedKeys) == Set([firstKey, secondKey]))
        #expect(service.workspaceGitMetadataFilesystemEventGeneration == initialGeneration + 1)
    }

    @Test func sharedWatchedPathsEventAssignsSameGenerationToEveryDirectory() throws {
        let firstDirectory = "/tmp/repo/frontend"
        let secondDirectory = "/tmp/repo/backend"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: firstDirectory)
        let secondPanelId = UUID()
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: ["/tmp/repo/.git/index"])
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "feature/x")),
            clock: ManualGitPollClock()
        )

        service.setWorkspaceGitMetadataWatcherSourceDirectory(firstDirectory, for: firstKey)
        service.setWorkspaceGitMetadataWatcherSourceDirectory(secondDirectory, for: secondKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: firstKey)
        service.setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: secondKey)
        service.markWorkspaceGitSnapshotCacheEligible(directory: firstDirectory)
        service.markWorkspaceGitSnapshotCacheEligible(directory: secondDirectory)
        let initialGeneration = service.workspaceGitMetadataFilesystemEventGeneration

        let refreshedKeys = service.recordWorkspaceGitMetadataFilesystemEvent(
            forWatchedPathsKey: watchedPathsKey
        )
        let firstGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: firstDirectory))
        let secondGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: secondDirectory))

        #expect(Set(refreshedKeys) == Set([firstKey, secondKey]))
        #expect(service.workspaceGitMetadataFilesystemEventGeneration == initialGeneration + 1)
        #expect(firstGeneration == secondGeneration)
    }

    @Test(.timeLimit(.minutes(1)))
    func joinedSnapshotWithNewGenerationQueuesFreshFollowUpProbe() async throws {
        let directory = "/tmp/repo"
        let host = RecordingSidebarGitHost()
        let (workspaceId, firstPanelId) = host.addWorkspace(panelDirectory: directory)
        let secondPanelId = UUID()
        host.workspaces[0].state.panels[secondPanelId] = RecordingSidebarGitHost.PanelState(
            directory: directory
        )
        let firstKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: firstPanelId)
        let secondKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: secondPanelId)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "feature/x"),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.workspaceGitTrackedDirectoryByKey[firstKey] = directory
        service.workspaceGitTrackedDirectoryByKey[secondKey] = directory
        service.markWorkspaceGitSnapshotCacheEligible(directory: directory)
        let firstGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: firstPanelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe(count: 1))

        service.recordWorkspaceGitMetadataFilesystemEvent(for: secondKey)
        let secondGeneration = try #require(service.workspaceGitSnapshotCacheGeneration(directory: directory))
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: secondPanelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil {
            service.workspaceGitProbeRerunPending(for: firstKey)
                && service.workspaceGitProbeRerunPending(for: secondKey)
        })

        let generations = await reader.probedTrackedPathEventGenerations
        #expect(secondGeneration != firstGeneration)
        let generation = try #require(generations.first ?? nil)
        #expect(generations.count == 1)
        #expect(generation.namespace == service.workspaceGitSnapshotCacheNamespace)
        #expect(generation.generation == firstGeneration)
        #expect(service.workspaceGitProbeRerunPending(for: firstKey))
        #expect(service.workspaceGitProbeRerunPending(for: secondKey))
        await reader.openGate()
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }

    @Test(.timeLimit(.minutes(1)))
    func repositorySnapshotProjectsRepositoryLink() async throws {
        let directory = "/tmp/repo"
        let link = GitRepositoryLink(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            url: URL(string: "https://github.com/manaflow-ai/cmux")!
        )
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "main", repositoryLink: link)
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "repositoryLink"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()

        #expect(await waitUntil {
            host.events.contains(
                .repositoryLink(
                    workspaceId,
                    panelId,
                    "origin",
                    "manaflow-ai/cmux",
                    URL(string: "https://github.com/manaflow-ai/cmux")!
                )
            )
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func laterSnapshotWithoutRepositoryLinkClearsLinkButKeepsValidBranch() async throws {
        let directory = "/tmp/repo"
        let link = GitRepositoryLink(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            url: URL(string: "https://github.com/manaflow-ai/cmux")!
        )
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "main", repositoryLink: link)
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "repositoryLinkPresent"
        )
        await clock.waitForSleeper(seconds: 0)
        await clock.resumeNext(seconds: 0)
        #expect(await waitUntil {
            host.events.contains {
                if case .repositoryLink(workspaceId, panelId, _, _, _) = $0 { return true }
                return false
            }
        })
        let probeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        #expect(await waitUntil { service.workspaceGitProbeStateByKey[probeKey] == nil })

        await reader.setMetadata(.repository(branch: "main"))
        let eventCountBeforeSecondProbe = host.events.count
        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "repositoryLinkRemoved"
        )
        await clock.waitForSleeper(seconds: 0)
        await clock.resumeNext(seconds: 0)

        #expect(await reader.waitForProbe(count: 2))
        #expect(await waitUntil {
            host.events.dropFirst(eventCountBeforeSecondProbe).contains(.clearRepositoryLink(workspaceId, panelId))
        })
        #expect(host.panelGitBranch(workspaceId: workspaceId, panelId: panelId)?.branch == "main")
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedDetachedHeadSnapshotKeepsUnchangedRepositoryLink() async throws {
        let directory = "/tmp/repo"
        let link = GitRepositoryLink(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            url: URL(string: "https://github.com/manaflow-ai/cmux")!
        )
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let reader = GatedMetadataReader(
            metadata: .repository(branch: nil, repositoryLink: link)
        )
        let firstClock = ManualGitPollClock()
        let firstService = makeService(host: host, reader: reader, clock: firstClock)

        firstService.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "detachedHeadInitial"
        )
        await firstClock.waitForSleeper()
        await firstClock.resumeNext()
        #expect(await waitUntil {
            host.panelRepositoryLink(workspaceId: workspaceId, panelId: panelId)?.url == link.url
        })
        let eventCountAfterFirstProbe = host.events.count
        let secondClock = ManualGitPollClock()
        let secondService = makeService(host: host, reader: reader, clock: secondClock)
        secondService.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "detachedHeadRepeat"
        )
        await secondClock.waitForSleeper()
        await secondClock.resumeNext()
        let secondProbeKey = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        #expect(await waitUntil { secondService.workspaceGitProbeStateByKey[secondProbeKey] == nil })

        #expect(host.panelRepositoryLink(workspaceId: workspaceId, panelId: panelId)?.url == link.url)
        let secondProbeEvents = host.events.dropFirst(eventCountAfterFirstProbe)
        #expect(!secondProbeEvents.contains(.clearRepositoryLink(workspaceId, panelId)))
        #expect(!secondProbeEvents.contains { event in
            if case .repositoryLink = event { return true }
            return false
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func clearingWorkspaceProbesClearsTrackedRepositoryLink() async throws {
        let directory = "/tmp/repo"
        let link = GitRepositoryLink(
            remoteName: "origin",
            displayName: "manaflow-ai/cmux",
            url: URL(string: "https://github.com/manaflow-ai/cmux")!
        )
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: directory)
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(
                metadata: .repository(branch: "main", repositoryLink: link)
            ),
            clock: clock
        )

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "repositoryLink"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil {
            host.panelRepositoryLink(workspaceId: workspaceId, panelId: panelId)?.url == link.url
        })

        service.clearWorkspaceGitProbes(workspaceId: workspaceId)

        #expect(host.panelRepositoryLink(workspaceId: workspaceId, panelId: panelId) == nil)
        #expect(host.events.contains(.clearRepositoryLink(workspaceId, panelId)))
    }
}
