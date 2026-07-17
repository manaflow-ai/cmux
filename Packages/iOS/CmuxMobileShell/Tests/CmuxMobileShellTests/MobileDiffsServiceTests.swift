import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileDiffsServiceTests {
    @Test func connectedClientWithoutRouteMetadataVendsWorkingService() async throws {
        let environment = try makeEnvironment()
        let service = try #require(environment.store.makeDiffsService())

        let summary = try await service.summary(
            workspaceRef: "workspace:restored",
            baseSpec: MobileDiffBaseSpec(kind: .workingTree),
            ignoreWhitespace: false
        )

        #expect(summary.totals == MobileDiffTotals(files: 1, additions: 2, deletions: 1))
        #expect(summary.files.first?.path == "Sources/App.swift")
        let request = try #require(await environment.host.recordedRequests().first)
        #expect(request.workspaceRef == "workspace:restored")
    }

    @Test func sendsExactFileAndContextRequestShapes() async throws {
        let environment = try makeEnvironment()
        let service = try #require(environment.store.makeDiffsService())
        let baseSpec = MobileDiffBaseSpec(kind: .branchBase, value: "origin/trunk")

        _ = try await service.fileHunks(
            workspaceRef: "workspace:42",
            path: "Sources/New.swift",
            oldPath: "Sources/Old.swift",
            baseSpec: baseSpec,
            ignoreWhitespace: true,
            cursor: 80,
            force: true
        )
        let context = try await service.contextRows(
            workspaceRef: "workspace:42",
            path: "Sources/New.swift",
            startLine: 4,
            endLine: 5,
            baseSpec: baseSpec,
            ignoreWhitespace: true
        )

        let requests = await environment.host.recordedRequests()
        let file = try #require(requests.first { $0.method == "mobile.workspace.diffs.file" })
        #expect(file.workspaceRef == "workspace:42")
        #expect(file.baseKind == "branchBase" && file.baseValue == "origin/trunk")
        #expect(file.ignoreWhitespace == true)
        #expect(file.path == "Sources/New.swift" && file.oldPath == "Sources/Old.swift")
        #expect(file.cursor == 80 && file.force == true)
        let contextRequest = try #require(requests.first { $0.method == "mobile.workspace.diffs.context" })
        #expect(contextRequest.startLine == 4 && contextRequest.endLine == 5)
        #expect(context.rows == ["line 4", "line 5"])
    }

    @Test func workspaceNotFoundMapsToTypedError() async throws {
        try await expectMappedError(code: "workspace_not_found", expected: .unknownWorkspace)
    }

    @Test func nonRepositoryMapsToTypedError() async throws {
        try await expectMappedError(code: "not_git_repository", expected: .notGitRepository)
    }

    @Test func unavailableBaselineMapsToDistinctTypedError() async throws {
        try await expectMappedError(code: "baseline_unavailable", expected: .baselineMissing)
    }

    @Test func workspaceDiffCapabilityUsesAdvertisedToken() {
        let store = MobileShellComposite.preview()
        #expect(store.supportsWorkspaceDiffs == false)

        store.supportedHostCapabilities = ["workspace.diffs.v1"]

        #expect(store.supportsWorkspaceDiffs)
    }

    private func expectMappedError(
        code: String,
        expected: MobileDiffsServiceError
    ) async throws {
        let environment = try makeEnvironment()
        await environment.host.setErrorCode(code)
        let service = try #require(environment.store.makeDiffsService())
        do {
            _ = try await service.summary(
                workspaceRef: "workspace:error",
                baseSpec: MobileDiffBaseSpec(kind: .workingTree)
            )
            Issue.record("Expected \(code) to throw")
        } catch let error as MobileDiffsServiceError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeEnvironment() throws -> (
        store: MobileShellComposite,
        host: MobileDiffsTestHost
    ) {
        let host = MobileDiffsTestHost()
        let runtime = MobileDiffsTestRuntime(
            transportFactory: MobileDiffsTestTransportFactory(host: host)
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            connectionState: .connected
        )
        let route = try CmxAttachRoute(
            id: "diffs-test",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56590)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "diffs-test-mac",
            macDisplayName: "Diffs Test Mac",
            routes: [route],
            authToken: "test-attach-token"
        )
        store.remoteClient = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true
        )
        return (store, host)
    }
}
