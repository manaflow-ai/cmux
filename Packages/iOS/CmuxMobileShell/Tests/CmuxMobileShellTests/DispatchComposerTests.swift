import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
private final class DispatchStubService: DispatchComposerServicing {
    var dispatchHostName: String? { "Stub Mac" }
    var dispatchIsConnected: Bool { true }
    let dispatchMacKey: String

    var catalog = DispatchCatalog(
        home: "/Users/stub",
        agents: [
            DispatchAgent(id: "claude", name: "Claude Code", installed: true),
            DispatchAgent(id: "codex", name: "Codex", installed: false),
        ],
        recentDirectories: [DispatchDirectory(path: "/Users/stub/Dev/proj", git: true)],
        promptByteBudget: 900
    )
    var catalogError: (any Error)?
    var launchResult: Result<Void, DispatchLaunchFailure> = .success(())
    var launchRequests: [(directory: String, agentID: String, prompt: String)] = []

    init(macKey: String = UUID().uuidString) {
        dispatchMacKey = macKey
    }

    func dispatchCatalog() async throws -> DispatchCatalog {
        if let catalogError { throw catalogError }
        return catalog
    }

    func dispatchFSList(path: String, includeHidden: Bool) async throws -> DispatchFSList {
        DispatchFSList(path: path, entries: [], notice: nil, truncated: false)
    }

    func dispatchFSSearch(query: String) async throws -> DispatchFSSearch {
        DispatchFSSearch(query: query, entries: [], indexing: false, truncated: false)
    }

    func dispatchLaunch(directory: String, agentID: String, prompt: String) async -> Result<Void, DispatchLaunchFailure> {
        launchRequests.append((directory, agentID, prompt))
        return launchResult
    }
}

@MainActor
@Suite struct DispatchComposerTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "dispatch-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func settledModel(
        service: DispatchStubService,
        defaults: UserDefaults
    ) async -> DispatchComposerModel {
        let model = DispatchComposerModel(
            service: service,
            localStore: DispatchLocalStore(defaults: defaults)
        )
        model.loadCatalogIfNeeded()
        for _ in 0 ..< 200 {
            if model.catalog != nil { break }
            await Task.yield()
        }
        return model
    }

    @Test func catalogDefaultsPickFirstRecentAndInstalledAgent() async {
        let service = DispatchStubService()
        let model = await settledModel(service: service, defaults: makeDefaults())

        #expect(model.directoryPath == "/Users/stub/Dev/proj")
        #expect(model.agentID == "claude")
    }

    @Test func emptyBriefNudgesBriefInsteadOfLaunching() async {
        let service = DispatchStubService()
        let model = await settledModel(service: service, defaults: makeDefaults())

        model.attemptDispatch()

        #expect(model.validationNudge == .brief)
        #expect(model.launchState == .idle)
        #expect(service.launchRequests.isEmpty)
    }

    @Test func overBudgetBriefNudgesBrief() async {
        let service = DispatchStubService()
        let model = await settledModel(service: service, defaults: makeDefaults())
        model.brief = String(repeating: "é", count: 500)

        #expect(model.isOverBudget)
        model.attemptDispatch()
        #expect(model.validationNudge == .brief)
        #expect(service.launchRequests.isEmpty)
    }

    @Test func successfulDispatchClearsDraftAndIncrementsSerial() async {
        let service = DispatchStubService()
        let defaults = makeDefaults()
        let model = await settledModel(service: service, defaults: defaults)
        model.brief = "  Ship the thing  "
        let serialBefore = model.serial

        model.attemptDispatch()
        for _ in 0 ..< 200 {
            if model.launchState == .dispatched { break }
            await Task.yield()
        }

        #expect(model.launchState == .dispatched)
        #expect(service.launchRequests.count == 1)
        #expect(service.launchRequests.first?.prompt == "Ship the thing")
        #expect(service.launchRequests.first?.directory == "/Users/stub/Dev/proj")
        let store = DispatchLocalStore(defaults: defaults)
        #expect(store.draft(macID: service.dispatchMacKey) == nil)
        #expect(store.nextSerial(macID: service.dispatchMacKey) == serialBefore + 1)
    }

    @Test func rejectedDispatchKeepsDraftAndClearsOnEdit() async {
        let service = DispatchStubService()
        service.launchResult = .failure(.agentNotInstalled)
        let defaults = makeDefaults()
        let model = await settledModel(service: service, defaults: defaults)
        model.brief = "Do the work"

        model.attemptDispatch()
        for _ in 0 ..< 200 {
            if case .rejected = model.launchState { break }
            await Task.yield()
        }

        #expect(model.launchState == .rejected(.agentNotInstalled))
        let store = DispatchLocalStore(defaults: defaults)
        #expect(store.draft(macID: service.dispatchMacKey)?.brief == "Do the work")

        model.brief = "Do the work now"
        #expect(model.launchState == .idle)
    }

    @Test func draftRestoresAcrossModelInstances() async {
        let service = DispatchStubService()
        let defaults = makeDefaults()
        let first = await settledModel(service: service, defaults: defaults)
        first.brief = "Persisted brief"
        first.selectDirectory("/Users/stub/Elsewhere")

        let second = DispatchComposerModel(
            service: service,
            localStore: DispatchLocalStore(defaults: defaults)
        )
        #expect(second.brief == "Persisted brief")
        #expect(second.directoryPath == "/Users/stub/Elsewhere")
    }

    @Test func uninstalledAgentCannotBeSelected() async {
        let service = DispatchStubService()
        let model = await settledModel(service: service, defaults: makeDefaults())

        model.selectAgent("codex")

        #expect(model.agentID == "claude")
    }

    @Test func launchFailureMapsWireCodes() {
        func failure(code: String?) -> DispatchLaunchFailure {
            MobileShellComposite.dispatchLaunchFailure(
                from: MobileShellConnectionError.rpcError(code, "m")
            )
        }
        #expect(failure(code: "agent_not_installed") == .agentNotInstalled)
        #expect(failure(code: "directory_not_found") == .directoryNotFound)
        #expect(failure(code: "prompt_too_long") == .promptTooLong)
        #expect(failure(code: "unavailable") == .notConnected)
        #expect(failure(code: "forbidden") == .authorizationFailed)
        #expect(failure(code: "somethingelse") == .rejected(message: "m"))
        #expect(
            MobileShellComposite.dispatchLaunchFailure(from: MobileShellConnectionError.requestTimedOut)
                == .requestTimedOut
        )
    }
}
