import Foundation
import CmuxFoundation
import CmuxGit
import Testing
@testable import CmuxSidebarGit

@MainActor
@Suite("Sidebar watcher registration", .timeLimit(.minutes(1)))
struct WatcherRegistrationLifecycleTests {
    private func service(
        host: RecordingSidebarGitHost,
        reader: GatedWatchDescriptorReader,
        gate: WatcherRegistrationGate
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: GatedMetadataReader(metadata: .repository(branch: "main")),
            gitMetadataService: reader,
            pullRequestProbing: RecordingPullRequestProbing(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 1),
            clock: ManualGitPollClock(),
            makeWatcher: { await gate.register($0) }
        )
        service.attach(host: host)
        return service
    }

    private func descriptor(_ root: String, identity: String = "index") -> GitWorkspaceMetadataWatchDescriptor {
        GitWorkspaceMetadataWatchDescriptor(
            repositoryRoot: root,
            watchedPaths: [root],
            gitMetadataPaths: [root + "/.git/index"],
            trackedEntryPaths: [],
            acceptsAllWorkTreeEvents: false,
            eventCoalescingInterval: .milliseconds(250),
            eventFilterIdentity: identity
        )
    }

    @Test func staleFailureCannotRemoveNewerDirectoryRequest() async throws {
        let host = RecordingSidebarGitHost()
        let (workspace, panel) = host.addWorkspace(panelDirectory: "/old")
        let key = WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)
        let reader = GatedWatchDescriptorReader()
        let gate = WatcherRegistrationGate()
        let service = service(host: host, reader: reader, gate: gate)
        defer { service.resetAllWorkspaceGitProbeTracking() }
        service.workspaceGitTrackedDirectoryByKey[key] = "/old"
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: "/old")
        let oldTask = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        #expect(await reader.nextRequestedDirectory() == "/old")
        await reader.resumeNext(with: descriptor("/old"))
        let oldID = try #require(await gate.nextArrival())

        service.workspaceGitTrackedDirectoryByKey[key] = "/new"
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: "/new")
        let newTask = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        #expect(await reader.nextRequestedDirectory() == "/new")
        await reader.resumeNext(with: descriptor("/new"))
        let newID = try #require(await gate.nextArrival())
        let newRequest = service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key]

        await gate.complete(oldID, with: nil)
        await oldTask.value
        #expect(service.workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == newRequest)
        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey[key] != "/old")
        await gate.complete(newID, with: nil)
        await newTask.value
        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey[key] == nil)
    }

    @Test func closedWorkspaceCannotBeResurrectedByRegistrationFailure() async throws {
        let host = RecordingSidebarGitHost()
        let (workspace, panel) = host.addWorkspace(panelDirectory: "/closed")
        let key = WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)
        let reader = GatedWatchDescriptorReader()
        let gate = WatcherRegistrationGate()
        let service = service(host: host, reader: reader, gate: gate)
        service.workspaceGitTrackedDirectoryByKey[key] = "/closed"
        service.updateWorkspaceGitMetadataWatcher(for: key, directory: "/closed")
        let task = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        _ = await reader.nextRequestedDirectory()
        await reader.resumeNext(with: descriptor("/closed"))
        let registration = try #require(await gate.nextArrival())
        service.clearWorkspaceGitProbes(workspaceId: workspace)
        await gate.complete(registration, with: nil)
        await task.value
        #expect(task.isCancelled)
        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherDescriptorRequestsByKey.isEmpty)
        #expect(service.workspaceGitMetadataWatcherTasksByKey.isEmpty)
    }

    @Test(arguments: [false, true])
    func failedForcedReplacementPreservesInstalledWatcherUntilLaterSuccess(descriptorFailure: Bool) async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let path = directoryURL.path
        let host = RecordingSidebarGitHost()
        let (workspace, panel) = host.addWorkspace(panelDirectory: path)
        let key = WorkspaceGitProbeKey(workspaceId: workspace, panelId: panel)
        let reader = GatedWatchDescriptorReader()
        let gate = WatcherRegistrationGate()
        let service = service(host: host, reader: reader, gate: gate)
        defer { service.resetAllWorkspaceGitProbeTracking() }
        service.workspaceGitTrackedDirectoryByKey[key] = path

        service.updateWorkspaceGitMetadataWatcher(for: key, directory: path)
        let initialTask = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        _ = await reader.nextRequestedDirectory()
        await reader.resumeNext(with: descriptor(path, identity: "initial"))
        let initialRegistration = try #require(await gate.nextArrival())
        let installed = try #require(await RecursivePathWatcher(paths: [path]))
        defer { Task { await installed.stop() } }
        await gate.complete(initialRegistration, with: installed)
        await initialTask.value
        let initialPathsKey = try #require(
            service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key]
        )
        let initialConsumer = try #require(
            service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[initialPathsKey]
        )

        service.updateWorkspaceGitMetadataWatcher(
            for: key, directory: path, forceDescriptorRefresh: true
        )
        let failedTask = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        _ = await reader.nextRequestedDirectory()
        if descriptorFailure {
            await reader.resumeNext(with: nil)
        } else {
            await reader.resumeNext(with: descriptor(path, identity: "replacement"))
            let failedRegistration = try #require(await gate.nextArrival())
            await gate.complete(failedRegistration, with: nil)
        }
        await failedTask.value

        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey[initialPathsKey] === installed)
        #expect(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] == initialPathsKey)
        #expect(service.workspaceGitMetadataWatcherSourceDirectoryByKey[key] == path)
        #expect(!initialConsumer.isCancelled)

        service.updateWorkspaceGitMetadataWatcher(
            for: key, directory: path, forceDescriptorRefresh: true
        )
        let replacementTask = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
        _ = await reader.nextRequestedDirectory()
        await reader.resumeNext(with: descriptor(path, identity: "replacement"))
        let replacementRegistration = try #require(await gate.nextArrival())
        let replacement = try #require(await RecursivePathWatcher(paths: [path]))
        defer { Task { await replacement.stop() } }
        await gate.complete(replacementRegistration, with: replacement)
        await replacementTask.value

        let replacementPathsKey = try #require(
            service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key]
        )
        #expect(replacementPathsKey != initialPathsKey)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey[replacementPathsKey] === replacement)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey[initialPathsKey] == nil)
        #expect(initialConsumer.isCancelled)
    }

    @Test func simultaneousPanelsPreserveOneInstalledWatcherAndConsumer() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sidebar-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let path = directoryURL.path
        let host = RecordingSidebarGitHost()
        let first = host.addWorkspace(panelDirectory: path)
        let second = host.addWorkspace(panelDirectory: path)
        let keys = [first, second].map { WorkspaceGitProbeKey(workspaceId: $0.0, panelId: $0.1) }
        let reader = GatedWatchDescriptorReader()
        let gate = WatcherRegistrationGate()
        let service = service(host: host, reader: reader, gate: gate)
        defer { service.resetAllWorkspaceGitProbeTracking() }
        var registrations: [(id: Int, task: Task<Void, Never>)] = []
        for key in keys {
            service.workspaceGitTrackedDirectoryByKey[key] = path
            service.updateWorkspaceGitMetadataWatcher(for: key, directory: path)
            let task = try #require(service.workspaceGitMetadataWatcherTasksByKey[key])
            _ = await reader.nextRequestedDirectory()
            await reader.resumeNext(with: descriptor(path))
            let id = try #require(await gate.nextArrival())
            registrations.append((id, task))
        }
        let installed = try #require(await RecursivePathWatcher(paths: [path]))
        let duplicate = try #require(await RecursivePathWatcher(paths: [path]))
        defer {
            Task { await installed.stop(); await duplicate.stop() }
        }
        await gate.complete(registrations[0].id, with: installed)
        await registrations[0].task.value
        let watchedKey = try #require(service.workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[keys[0]])
        let consumer = try #require(service.workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedKey])
        await gate.complete(registrations[1].id, with: duplicate)
        await registrations[1].task.value
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey.count == 1)
        #expect(service.workspaceGitMetadataWatchersByWatchedPathsKey[watchedKey] === installed)
        #expect(service.workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedKey] == Set(keys))
        #expect(!consumer.isCancelled)
    }
}
