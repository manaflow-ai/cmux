import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Shared fixtures for the render-grid liveness watchdog tests
// (MobileShellRenderGridLivenessTests.swift): injected clock, scripted
// host router, transport mocks, and the connected-store builder.

// MARK: - Scripted host (router + transport)

/// Scripts the Mac side of the persistent RPC connection: answers the
/// connect-time `workspace.list`, the `mobile.host.status` capability and
/// probe requests, `mobile.events.subscribe`, and replay/viewport calls.
/// Individual requests can be held unresolved to model an ack that has not
/// arrived yet (establishment window) or a host that stopped answering
/// (dead stream).
actor LivenessHostRouter {
    struct RecordedRequest: Sendable {
        var method: String?
        var topics: [String]?
        var workspaceID: String?
        var streamID: String?
        var viewportColumns: Int?
        var viewportRows: Int?
        var viewportGeneration: Int?
        var clearsViewport: Bool
        var groupID: String?
        var action: String?
        var title: String?
        var attachToken: String?
        var stackAccessToken: String?
    }

    private var recorded: [RecordedRequest] = []
    private var attachTicketFailuresRemaining = 0
    private var countWaiters: [(
        id: UUID,
        method: String,
        expectedCount: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var hostStatusRequestCount = 0
    private var heldHostStatusRequestNumbers: Set<Int> = []
    private var delayedHostStatusRequestNumbers: Set<Int> = []
    private var omittedHostIdentityResponsesRemaining = 0
    private var workspaceListRequestCount = 0
    private var heldWorkspaceListRequestNumbers: Set<Int> = []
    private var workspaceListErrorCodesByRequestNumber: [Int: String] = [:]
    private var subscribeRequestCount = 0
    private var probeRequestCount = 0
    private var heldSubscribeRequestNumbers: Set<Int> = []
    private var heldProbeRequestNumbers: Set<Int> = []
    private var delayedSubscribeRequestNumbers: Set<Int> = []
    private var invalidSubscribeRequestNumbers: Set<Int> = []
    private var subscribeErrorCodesByRequestNumber: [Int: String] = [:]
    private var holdSubscribe = false
    private var unsubscribeRequestCount = 0
    private var heldUnsubscribeRequestNumbers: Set<Int> = []
    private var invalidUnsubscribeRequestNumbers: Set<Int> = []
    private var notificationFeedRevision = 0
    private var notificationFeedRevisions: [Int] = []
    private var notificationFeedFailuresRemaining = 0
    private var notificationFeedRequestCount = 0
    private var heldNotificationFeedRequestNumbers: Set<Int> = []
    private var replayRequestCount = 0
    private var replayResponseCount = 0
    private var heldReplayRequestNumbers: Set<Int> = []
    private var heldReplayResponsesRemaining = 0
    private var syncFetchRequestCount = 0
    private var heldSyncFetchRequestNumbers: Set<Int> = []
    private var viewportRequestCount = 0
    private var heldViewportRequestNumbers: Set<Int> = []
    private var hasActiveSubscription = false
    private var terminalInputSequences: [UInt64] = []
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var capabilities = ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"]
    // This router models the current authenticated Mac host by default. Tests
    // for legacy identity omission opt out explicitly via `setHostIdentity`.
    // Supplying the matching instance identity also keeps unrelated liveness
    // tests from exercising the one-shot legacy identity recovery request.
    private var macDeviceID: String? = "test-mac"
    private var macInstanceTag: String? = "default"
    private var macClientNamespace: String? = "mac:com.cmuxterm.app.debug"
    private var macDisplayName: String? = "Test Mac"
    private var workspaceListResponseHook: (@Sendable () -> Void)?
    private var workspaceIDs = ["live-workspace"]
    private var workspaceListTitles: [String] = []
    /// FIFO of scripted `mobile.sync.fetch` results (state sync v2 tests).
    private var syncFetchResults: [[String: Any]] = []
    private var replayPayloads: [(text: String?, sequence: UInt64?, renderGrid: MobileTerminalRenderGridFrame?)] = []
    private var replayTexts: [String] = []
    private var replayFailuresRemaining = 0
    private var replayFailureCode: String?
    private var emptyReplayResponsesRemaining = 0; private var viewportEffectiveGridOverride: LivenessViewportReport?; private var emptyViewportResponsesRemaining = 0

    /// Scripts the next `mobile.sync.fetch` answer (state sync v2 tests). The
    /// payload crosses the actor boundary as encoded JSON so the test-side
    /// builder can use `JSONSerialization` freely without Sendable friction.
    func scriptSyncFetchResult(jsonData: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any] else {
            return
        }
        syncFetchResults.append(object)
    }

    /// Scripts the next `mobile.sync.fetch` to fail with a transient (non
    /// method_not_found) error, modeling a timeout/decoding failure mid-repair.
    func scriptSyncFetchTransientError() {
        syncFetchResults.append(["__transient_error__": true])
    }

    /// Hold the Nth `mobile.sync.fetch` response (1-based), allowing tests to
    /// issue another refresh request while a cursor fetch is still in flight.
    func holdSyncFetchRequest(number: Int) {
        heldSyncFetchRequestNumbers.insert(number)
    }

    func record(
        method: String?,
        topics: [String]?,
        workspaceID: String? = nil,
        streamID: String? = nil,
        viewportColumns: Int? = nil,
        viewportRows: Int? = nil,
        viewportGeneration: Int? = nil,
        clearsViewport: Bool = false,
        groupID: String? = nil,
        action: String? = nil,
        title: String? = nil,
        attachToken: String? = nil,
        stackAccessToken: String? = nil
    ) {
        recorded.append(RecordedRequest(
            method: method,
            topics: topics,
            workspaceID: workspaceID,
            streamID: streamID,
            viewportColumns: viewportColumns,
            viewportRows: viewportRows,
            viewportGeneration: viewportGeneration,
            clearsViewport: clearsViewport,
            groupID: groupID,
            action: action,
            title: title,
            attachToken: attachToken,
            stackAccessToken: stackAccessToken
        ))
        resumeSatisfiedCountWaiters()
    }

    func count(of method: String) -> Int {
        recorded.filter { $0.method == method }.count
    }

    func requests(for method: String) -> [RecordedRequest] {
        recorded.filter { $0.method == method }
    }

    func heldRequestCount() -> Int {
        heldContinuations.count
    }

    func failNextAttachTicketRequests(count: Int = 1) {
        attachTicketFailuresRemaining += count
    }

    func replayResponsesServed() -> Int {
        replayResponseCount
    }

    @discardableResult
    func waitForCount(
        of method: String,
        atLeast expectedCount: Int,
        timeoutNanoseconds: UInt64 = MobileShellWallClockWaitPolicy.defaultWaitTimeoutNanoseconds,
        recordIssueOnTimeout: Bool = true
    ) async -> Bool {
        let effectiveTimeoutNanoseconds = MobileShellWallClockWaitPolicy
            .timeoutNanoseconds(for: timeoutNanoseconds)
        let operation: @Sendable () async throws -> Bool = {
            try Task.checkCancellation()
            return await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await self.waitUntilCountReached(of: method, atLeast: expectedCount)
                    return true
                }
                group.addTask {
                    // Test assertion deadline only; request arrival is signaled by record().
                    try? await Task.sleep(nanoseconds: effectiveTimeoutNanoseconds)
                    return false
                }
                let reached = await group.next() ?? false
                group.cancelAll()
                return reached
            }
        }
        let reached: Bool
        if MobileShellWallClockWaitPolicy.shouldSerializeWait(
            timeoutNanoseconds: timeoutNanoseconds
        ) {
            reached = (try? await MobileShellWallClockWaitGate.processWide.withLock(operation)) ?? false
        } else {
            reached = (try? await operation()) ?? false
        }
        if !reached, recordIssueOnTimeout {
            Issue.record("timed out waiting for \(method) count >= \(expectedCount)")
        }
        return reached
    }

    /// Waits for the transport's real replay-request admission signal. This
    /// is used by tests that need to distinguish an already-started request
    /// from one that must wait for an output acknowledgement.
    @discardableResult
    func waitForReplayRequestStart(
        after existingCount: Int,
        timeoutNanoseconds: UInt64 = 250_000_000
    ) async -> Bool {
        await waitForCount(
            of: "mobile.terminal.replay",
            atLeast: existingCount + 1,
            timeoutNanoseconds: timeoutNanoseconds,
            recordIssueOnTimeout: false
        )
    }

    private func waitUntilCountReached(of method: String, atLeast expectedCount: Int) async {
        guard count(of: method) < expectedCount else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                countWaiters.append((
                    id: waiterID,
                    method: method,
                    expectedCount: expectedCount,
                    continuation: continuation
                ))
                resumeSatisfiedCountWaiters()
            }
        } onCancel: {
            Task { await self.cancelCountWaiter(id: waiterID) }
        }
    }

    private func resumeSatisfiedCountWaiters() {
        var remaining: [(
            id: UUID,
            method: String,
            expectedCount: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        var satisfied: [CheckedContinuation<Void, Never>] = []
        for waiter in countWaiters {
            if count(of: waiter.method) >= waiter.expectedCount {
                satisfied.append(waiter.continuation)
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
        for continuation in satisfied {
            continuation.resume()
        }
    }

    private func cancelCountWaiter(id: UUID) {
        guard let index = countWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = countWaiters.remove(at: index)
        waiter.continuation.resume()
    }

    func topics(for method: String) -> [[String]] {
        recorded.compactMap { request in
            guard request.method == method else { return nil }
            return request.topics
        }
    }

    func workspaceIDs(for method: String) -> [String?] {
        recorded.filter { $0.method == method }.map(\.workspaceID)
    }

    func streamIDs(for method: String) -> [String?] {
        recorded.filter { $0.method == method }.map(\.streamID)
    }

    func groupActions() -> [(groupID: String?, action: String?, title: String?)] {
        recorded.filter { $0.method == "workspace.group.action" }.map {
            (groupID: $0.groupID, action: $0.action, title: $0.title)
        }
    }

    func authorization(for method: String) -> [(attachToken: String?, stackAccessToken: String?)] {
        recorded.filter { $0.method == method }.map {
            (attachToken: $0.attachToken, stackAccessToken: $0.stackAccessToken)
        }
    }

    func setCapabilities(_ capabilities: [String]) {
        self.capabilities = capabilities
    }

    func setHostIdentity(
        deviceID: String?,
        instanceTag: String?,
        displayName: String? = nil,
        clientNamespace: String? = "mac:com.cmuxterm.app.debug"
    ) {
        macDeviceID = deviceID
        macInstanceTag = instanceTag
        macClientNamespace = clientNamespace
        macDisplayName = displayName
    }

    func omitNextHostStatusIdentities(count: Int = 1) {
        omittedHostIdentityResponsesRemaining += count
    }

    func setWorkspaceListResponseHook(_ hook: @escaping @Sendable () -> Void) {
        workspaceListResponseHook = hook
    }

    func enqueueReplayTexts(_ texts: [String]) {
        replayTexts.append(contentsOf: texts)
    }

    func enqueueReplayPayload(text: String?, sequence: UInt64?) {
        replayPayloads.append((text: text, sequence: sequence, renderGrid: nil))
    }

    func enqueueReplayRenderGrid(_ renderGrid: MobileTerminalRenderGridFrame) {
        replayPayloads.append((text: nil, sequence: nil, renderGrid: renderGrid))
    }

    func enqueueReplayRenderGridFrames(_ frames: [MobileTerminalRenderGridFrame]) {
        for frame in frames {
            enqueueReplayRenderGrid(frame)
        }
    }

    func failNextReplay(count: Int = 1) {
        replayFailureCode = nil
        replayFailuresRemaining += count
    }

    func failNextReplay(code: String, count: Int = 1) {
        replayFailureCode = code
        replayFailuresRemaining += count
    }

    func enqueueEmptyReplayResponses(count: Int = 1) {
        emptyReplayResponsesRemaining += count
    }

    func enqueueTerminalInputSequences(_ sequences: [UInt64]) {
        terminalInputSequences.append(contentsOf: sequences)
    }

    /// Hold every `mobile.events.subscribe` response until released.
    func setHoldSubscribe(_ hold: Bool) {
        holdSubscribe = hold
    }

    /// Hold the Nth `mobile.host.status` request (1-based) forever, modeling
    /// a host that stopped answering on a half-dead transport.
    func holdHostStatusRequest(number: Int) {
        heldHostStatusRequestNumbers.insert(number)
    }

    /// Delay the Nth status response until released, then return its ordinary
    /// payload. Unlike ``holdHostStatusRequest``, this models a slow healthy
    /// dial instead of a half-dead transport.
    func delayHostStatusRequest(number: Int) {
        delayedHostStatusRequestNumbers.insert(number)
    }

    /// Hold the Nth workspace-list response so tests can change persisted
    /// per-Mac authority while a secondary snapshot is in flight.
    func holdWorkspaceListRequest(number: Int) {
        heldWorkspaceListRequestNumbers.insert(number)
    }

    func failWorkspaceListRequest(
        number: Int,
        code: String = "workspace_list_failed"
    ) {
        workspaceListErrorCodesByRequestNumber[number] = code
    }

    func scriptWorkspaceListTitles(_ titles: [String]) {
        workspaceListTitles.append(contentsOf: titles)
    }

    func setWorkspaceIDs(_ workspaceIDs: [String]) {
        self.workspaceIDs = workspaceIDs
    }

    func scriptNotificationFeedRevisions(_ revisions: [Int]) {
        notificationFeedRevisions.append(contentsOf: revisions)
    }

    func holdNotificationFeedListRequest(number: Int) {
        heldNotificationFeedRequestNumbers.insert(number)
    }

    /// Hold the next workspace-list responses relative to requests already seen.
    func holdNextWorkspaceListRequests(count: Int = 1) {
        guard count > 0 else { return }
        for offset in 1 ... count {
            heldWorkspaceListRequestNumbers.insert(workspaceListRequestCount + offset)
        }
    }

    /// Hold the Nth `mobile.events.subscribe` request (1-based) forever,
    /// modeling a dead push path whose probe never completes.
    func holdSubscribeRequest(number: Int) {
        heldSubscribeRequestNumbers.insert(number)
    }

    /// Hold the Nth read-only subscription probe (1-based) forever.
    func holdProbeRequest(number: Int) {
        heldProbeRequestNumbers.insert(number)
    }

    /// Delay a subscribe acknowledgement until released, then return the
    /// ordinary successful payload.
    func delaySubscribeRequest(number: Int) {
        delayedSubscribeRequestNumbers.insert(number)
    }

    /// Return an acknowledgement without the requested stream id.
    func invalidateSubscribeRequest(number: Int) {
        invalidSubscribeRequestNumbers.insert(number)
    }

    func failSubscribeRequest(
        number: Int,
        code: String = "subscribe_failed"
    ) {
        subscribeErrorCodesByRequestNumber[number] = code
    }

    /// Return a malformed acknowledgement for the Nth unsubscribe request.
    func invalidateUnsubscribeRequest(number: Int) {
        invalidUnsubscribeRequestNumbers.insert(number)
    }

    func holdUnsubscribeRequest(number: Int) {
        heldUnsubscribeRequestNumbers.insert(number)
    }

    func failNextNotificationFeedLists(count: Int = 1) {
        notificationFeedFailuresRemaining += count
    }

    /// Hold the Nth `mobile.terminal.replay` response (1-based), letting a test
    /// swap clients while the old request is still in flight.
    func holdReplayRequest(number: Int) {
        heldReplayRequestNumbers.insert(number)
    }

    /// Hold the next N `mobile.terminal.replay` responses, independent of any
    /// replay requests the connect/mount path already used.
    func holdNextReplayResponses(count: Int = 1) {
        heldReplayResponsesRemaining += count
    }

    /// Hold the Nth `mobile.terminal.viewport` response (1-based), allowing a
    /// later viewport report to acknowledge before an older one.
    func holdViewportRequest(number: Int) {
        heldViewportRequestNumbers.insert(number)
    }

    func setViewportEffectiveGrid(columns: Int, rows: Int) { viewportEffectiveGridOverride = .init(columns: columns, rows: rows) }; func emptyNextViewportResponses(count: Int = 1) { emptyViewportResponsesRemaining += count }

    /// Forget the host-side registration, modeling a lost subscription behind
    /// a live RPC channel: the next subscribe reports
    /// `already_subscribed: false`.
    func dropSubscription() {
        hasActiveSubscription = false
    }

    /// Resume every held request so parked continuations do not leak past the
    /// end of the test.
    func releaseAllHeld() {
        holdSubscribe = false
        heldHostStatusRequestNumbers = []
        delayedHostStatusRequestNumbers = []
        heldWorkspaceListRequestNumbers = []
        heldSubscribeRequestNumbers = []
        heldProbeRequestNumbers = []
        delayedSubscribeRequestNumbers = []
        heldUnsubscribeRequestNumbers = []
        heldNotificationFeedRequestNumbers = []
        heldReplayRequestNumbers = []
        heldReplayResponsesRemaining = 0
        heldSyncFetchRequestNumbers = []
        heldViewportRequestNumbers = []
        let continuations = heldContinuations
        heldContinuations = []
        for continuation in continuations { continuation.resume() }
    }

    func releaseNextHeld() {
        guard !heldContinuations.isEmpty else { return }
        heldContinuations.removeFirst().resume()
    }

    func response(
        method: String?,
        id: String?,
        streamID: String? = nil,
        viewportReport: LivenessViewportReport? = nil
    ) async -> Data? {
        switch method {
        case "mobile.attach_ticket.create":
            if attachTicketFailuresRemaining > 0 {
                attachTicketFailuresRemaining -= 1
                return try? Self.errorFrame(
                    id: id,
                    code: "internal",
                    message: "scripted attach ticket failure"
                )
            }
            return try? Self.resultFrame(id: id, result: ["ticket": Self.attachTicketObject()])
        case "workspace.list", "mobile.workspace.list":
            workspaceListRequestCount += 1
            let workspaceTitle = workspaceListTitles.isEmpty
                ? "Live Workspace"
                : workspaceListTitles.removeFirst()
            if heldWorkspaceListRequestNumbers.contains(workspaceListRequestCount) {
                await park()
            }
            workspaceListResponseHook?()
            if let errorCode =
                workspaceListErrorCodesByRequestNumber[
                    workspaceListRequestCount
                ] {
                return try? Self.errorFrame(
                    id: id,
                    code: errorCode,
                    message: "scripted workspace list failure"
                )
            }
            let workspaces: [[String: Any]] = workspaceIDs.enumerated().map { index, workspaceID in
                [
                    "id": workspaceID,
                    "title": index == 0 ? workspaceTitle : workspaceID,
                    "current_directory": "/Users/test/project",
                    "is_selected": index == 0,
                    "terminals": [
                        [
                            "id": workspaceID == "live-workspace"
                                ? "live-terminal"
                                : "\(workspaceID)-terminal",
                            "title": "Terminal",
                            "current_directory": "/Users/test/project",
                            "is_ready": true,
                            "is_focused": true,
                        ],
                    ],
                ]
            }
            return try? Self.resultFrame(id: id, result: [
                "workspaces": workspaces,
            ])
        case "mobile.host.status":
            hostStatusRequestCount += 1
            if heldHostStatusRequestNumbers.contains(hostStatusRequestCount) {
                await park()
                return nil
            }
            if delayedHostStatusRequestNumbers.contains(
                hostStatusRequestCount
            ) {
                await park()
            }
            var result: [String: Any] = [
                "terminal_fidelity": "render_grid",
                "capabilities": capabilities,
            ]
            let omitsIdentity = omittedHostIdentityResponsesRemaining > 0
            if omitsIdentity {
                omittedHostIdentityResponsesRemaining -= 1
            } else {
                if let macDeviceID { result["mac_device_id"] = macDeviceID }
                if let macInstanceTag { result["mac_instance_tag"] = macInstanceTag }
                if let macClientNamespace {
                    result["mac_client_namespace"] = macClientNamespace
                }
                if let macDisplayName { result["mac_display_name"] = macDisplayName }
            }
            return try? Self.resultFrame(id: id, result: result)
        case "mobile.events.subscribe":
            subscribeRequestCount += 1
            if holdSubscribe || heldSubscribeRequestNumbers.contains(subscribeRequestCount) {
                await park()
                return nil
            }
            if delayedSubscribeRequestNumbers.contains(subscribeRequestCount) {
                await park()
            }
            if let errorCode =
                subscribeErrorCodesByRequestNumber[subscribeRequestCount] {
                return try? Self.errorFrame(
                    id: id,
                    code: errorCode,
                    message: "scripted subscribe failure"
                )
            }
            let alreadySubscribed = hasActiveSubscription
            hasActiveSubscription = true
            return try? Self.resultFrame(id: id, result: [
                "stream_id": invalidSubscribeRequestNumbers.contains(
                    subscribeRequestCount
                ) ? "" : (streamID ?? ""),
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": alreadySubscribed,
            ])
        case "mobile.events.probe":
            probeRequestCount += 1
            if heldProbeRequestNumbers.contains(probeRequestCount) {
                await park()
                return nil
            }
            return try? Self.resultFrame(id: id, result: [
                "stream_id": streamID ?? "",
                "subscribed": hasActiveSubscription,
                "event_transport": "control_v1",
            ])
        case "workspace.group.action":
            return try? Self.resultFrame(id: id, result: [:])
        case "mobile.terminal.replay":
            replayRequestCount += 1
            if heldReplayResponsesRemaining > 0 {
                heldReplayResponsesRemaining -= 1
                await park()
            } else if heldReplayRequestNumbers.contains(replayRequestCount) {
                await park()
            }
            defer {
                replayResponseCount += 1
            }
            if replayFailuresRemaining > 0 {
                replayFailuresRemaining -= 1
                let failureCode = replayFailureCode
                if replayFailuresRemaining == 0 {
                    replayFailureCode = nil
                }
                return try? Self.errorFrame(
                    id: id,
                    code: failureCode,
                    message: "replay failed"
                )
            }
            if emptyReplayResponsesRemaining > 0 {
                emptyReplayResponsesRemaining -= 1
                return try? Self.resultFrame(id: id, result: [:])
            }
            if !replayPayloads.isEmpty {
                let payload = replayPayloads.removeFirst()
                var result: [String: Any] = [:]
                if let text = payload.text {
                    result["data_b64"] = Data(text.utf8).base64EncodedString()
                }
                if let sequence = payload.sequence {
                    result["seq"] = sequence
                }
                if let renderGrid = payload.renderGrid,
                   let renderGridObject = try? renderGrid.jsonObject() {
                    result["render_grid"] = renderGridObject
                    result["columns"] = renderGrid.columns
                    result["rows"] = renderGrid.rows
                    if result["seq"] == nil {
                        result["seq"] = renderGrid.stateSeq
                    }
                }
                return try? Self.resultFrame(id: id, result: result)
            }
            guard !replayTexts.isEmpty else {
                return try? Self.resultFrame(id: id, result: [:])
            }
            let text = replayTexts.removeFirst()
            return try? Self.resultFrame(id: id, result: [
                "data_b64": Data(text.utf8).base64EncodedString(),
            ])
        case "mobile.events.unsubscribe":
            unsubscribeRequestCount += 1
            if heldUnsubscribeRequestNumbers.contains(
                unsubscribeRequestCount
            ) {
                await park()
            }
            guard !invalidUnsubscribeRequestNumbers.contains(unsubscribeRequestCount) else {
                return try? Self.resultFrame(id: id, result: [:])
            }
            return try? Self.resultFrame(id: id, result: [
                "stream_id": streamID ?? "",
                "removed": true,
            ])
        case "notification.feed.list":
            notificationFeedRequestCount += 1
            if heldNotificationFeedRequestNumbers.contains(
                notificationFeedRequestCount
            ) {
                await park()
            }
            if notificationFeedFailuresRemaining > 0 {
                notificationFeedFailuresRemaining -= 1
                return try? Self.errorFrame(
                    id: id,
                    message: "scripted notification feed failure"
                )
            }
            if notificationFeedRevisions.isEmpty {
                notificationFeedRevision += 1
            } else {
                notificationFeedRevision =
                    notificationFeedRevisions.removeFirst()
            }
            return try? Self.resultFrame(id: id, result: [
                "revision": notificationFeedRevision,
                "notifications": [],
            ])
        case "mobile.sync.fetch":
            syncFetchRequestCount += 1
            if heldSyncFetchRequestNumbers.contains(syncFetchRequestCount) {
                await park()
            }
            // Unscripted routers model a legacy Mac: the real host answers an
            // unknown method with `method_not_found`, which the shell treats
            // as "stay on the workspace.updated refetch loop".
            guard !syncFetchResults.isEmpty else {
                return try? Self.errorFrame(id: id, code: "method_not_found", message: "Unknown mobile method")
            }
            let scripted = syncFetchResults.removeFirst()
            if scripted["__transient_error__"] as? Bool == true {
                return try? Self.errorFrame(id: id, message: "scripted transient sync failure")
            }
            return try? Self.resultFrame(id: id, result: scripted)
        case "mobile.terminal.viewport":
            viewportRequestCount += 1
            if heldViewportRequestNumbers.contains(viewportRequestCount) {
                await park()
            }
            if emptyViewportResponsesRemaining > 0 { emptyViewportResponsesRemaining -= 1; return try? Self.resultFrame(id: id, result: [:]) }
            // Mirror the Mac host: acknowledge the report with the effective
            // shared grid. Echoing the reported viewport models a single
            // attached device, whose report is always the effective minimum.
            var result: [String: Any] = [:]
            if let viewportReport = viewportEffectiveGridOverride ?? viewportReport { result["columns"] = viewportReport.columns; result["rows"] = viewportReport.rows }
            return try? Self.resultFrame(id: id, result: result)
        case "terminal.input":
            let terminalSequence = terminalInputSequences.isEmpty
                ? 100
                : terminalInputSequences.removeFirst()
            return try? Self.resultFrame(id: id, result: [
                "terminal_seq": terminalSequence,
            ])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

    private func park() async {
        await withCheckedContinuation { continuation in
            heldContinuations.append(continuation)
        }
    }

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, code: String? = nil, message: String) throws -> Data {
        var error: [String: Any] = ["message": message]
        if let code { error["code"] = code }
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": error,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}

/// Holds the live transport instance so the test can push unsolicited
/// server-side event frames through the same receive path production uses.
final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: LivenessTransport?

    func set(_ transport: LivenessTransport) {
        lock.withLock { self.transport = transport }
    }

    func get() -> LivenessTransport? {
        lock.withLock { transport }
    }
}

struct LivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox
    var closeGate: LivenessTransportCloseGate?

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = LivenessTransport(
            router: router,
            closeGate: closeGate
        )
        box.set(transport)
        return transport
    }
}

actor LivenessTransport: CmxByteTransport {
    private let router: LivenessHostRouter
    private let closeGate: LivenessTransportCloseGate?
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(
        router: LivenessHostRouter,
        closeGate: LivenessTransportCloseGate? = nil
    ) {
        self.router = router
        self.closeGate = closeGate
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw MobileShellConnectionError.connectionClosed }
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let method = parsed?["method"] as? String
            let id = parsed?["id"] as? String
            let params = parsed?["params"] as? [String: Any]
            let auth = parsed?["auth"] as? [String: Any]
            let topics = params?["topics"] as? [String]
            let streamID = params?["stream_id"] as? String
            let viewportReport: LivenessViewportReport? = {
                guard method == "mobile.terminal.viewport",
                      let columns = (params?["viewport_columns"] as? NSNumber)?.intValue,
                      let rows = (params?["viewport_rows"] as? NSNumber)?.intValue else {
                    return nil
                }
                return LivenessViewportReport(columns: columns, rows: rows)
            }()
            await router.record(
                method: method,
                topics: topics,
                workspaceID: params?["workspace_id"] as? String,
                streamID: streamID,
                viewportColumns: (params?["viewport_columns"] as? NSNumber)?.intValue,
                viewportRows: (params?["viewport_rows"] as? NSNumber)?.intValue,
                viewportGeneration: (params?["viewport_generation"] as? NSNumber)?.intValue,
                clearsViewport: params?["clear"] as? Bool == true,
                groupID: params?["group_id"] as? String,
                action: params?["action"] as? String,
                title: params?["title"] as? String,
                attachToken: auth?["attach_token"] as? String,
                stackAccessToken: auth?["stack_access_token"] as? String
            )
            // Answer each request concurrently so one held response cannot
            // head-of-line block later RPCs, matching the Mac host's
            // per-frame response tasks.
            Task { [router, weak self] in
                guard let response = await router.response(
                    method: method,
                    id: id,
                    streamID: streamID,
                    viewportReport: viewportReport
                ) else {
                    return
                }
                await self?.deliver(response)
            }
        }
    }

    func close() async {
        await closeGate?.waitForRelease()
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func isClosedForTesting() -> Bool {
        isClosed
    }

    /// Deliver a frame to the client's read loop. Also used by tests to push
    /// unsolicited server-side event envelopes.
    func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}

// MARK: - Test helpers

@MainActor
final class OutputCollector {
    private(set) var lines: [String] = []
    private(set) var viewportPolicies: [MobileTerminalOutputViewportPolicy?] = []
    private var task: Task<Void, Never>?

    func mount(store: MobileShellComposite, surfaceID: String) {
        task = Task { @MainActor [weak self] in
            for await chunk in store.terminalOutputStream(surfaceID: surfaceID) {
                self?.lines.append(String(decoding: chunk.data, as: UTF8.self))
                self?.viewportPolicies.append(chunk.viewportPolicy)
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken
                )
            }
        }
    }

    func unmount() {
        task?.cancel()
        task = nil
    }
}

func makeTicket(clock: TestClock) throws -> CmxAttachTicket {
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56584)
    )
    return try CmxAttachTicket(
        workspaceID: "live-workspace",
        terminalID: "live-terminal",
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
        routes: [route],
        expiresAt: clock.now.addingTimeInterval(3600)
    )
}

func attachURL(for ticket: CmxAttachTicket) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(ticket)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)"
}

/// Poll until `condition` is true, bounded at `attempts` x 10ms. The default
/// budget is intentionally generous for whole-suite scheduling; callers that
/// assert bounded absence can keep an explicit shorter attempt count. Returns
/// the final value so tests can assert both presence and (bounded) absence.
@MainActor
func pollUntil(
    attempts: Int = MobileShellWallClockWaitPolicy.defaultPollAttempts,
    _ condition: @MainActor () async -> Bool
) async throws -> Bool {
    let operation: @Sendable () async throws -> Bool = {
        try Task.checkCancellation()
        for _ in 0..<attempts {
            if await condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
    if MobileShellWallClockWaitPolicy.shouldSerializePoll(attempts: attempts) {
        return try await MobileShellWallClockWaitGate.processWide.withLock(operation)
    }
    return try await operation()
}

@MainActor
func waitForReplayResponsesServed(
    _ expectedCount: Int,
    router: LivenessHostRouter,
    _ message: String
) async throws {
    let settled = try await pollUntil {
        await router.replayResponsesServed() >= expectedCount
    }
    #expect(settled, "\(message)")
}

@MainActor
func makeConnectedStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    probeTimeoutNanoseconds: UInt64 = 200_000_000,
    inputAckRetryClock: any Clock<Duration> = ContinuousClock(),
    controlPlaneSchedulingClock: any Clock<Duration> = ContinuousClock()
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now },
        livenessProbeTimeoutNanoseconds: probeTimeoutNanoseconds
    )
    let store = MobileShellComposite.preview(
        runtime: runtime,
        terminalInputAckResubscribeClock: inputAckRetryClock,
        controlPlaneSchedulingClock: controlPlaneSchedulingClock
    )
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    let capabilitiesResolved = try await pollUntil {
        !store.supportedHostCapabilities.isEmpty
    }
    #expect(capabilitiesResolved, "scripted connect must resolve host capabilities")
    return store
}

@MainActor
func installFreshLivenessRemoteClient(
    on store: MobileShellComposite,
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock
) throws {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let ticket = try makeTicket(clock: clock)
    let route = try #require(ticket.routes.first)
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
}
