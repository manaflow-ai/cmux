import AppKit
import CCmuxTerminal
import CoreGraphics
import Foundation
import Testing
@testable import NativeMuxDemo

private let testLocalization = Localization.fallback

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
private final class TestDemoWindowPlacementWindow: DemoWindowPlacementWindow {
    let placementVisibleFrame: CGRect?
    private(set) var appliedFrame: CGRect?

    init(visibleFrame: CGRect?) {
        placementVisibleFrame = visibleFrame
    }

    func applyPlacementFrame(_ frame: CGRect) {
        appliedFrame = frame
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

private func nativeResetPayload() -> Data {
    var payload = Data("CMNR".utf8)
    payload.append(1)
    payload.append(contentsOf: UInt32(3).littleEndianBytes)
    payload.append(contentsOf: UInt16(1).littleEndianBytes)
    for value in [UInt64(10), UInt64(20), UInt64(30), UInt64(40)] {
        payload.append(contentsOf: value.littleEndianBytes)
    }
    for value in [UInt32(2), UInt32(3), UInt32(4), UInt32(5), UInt32(6)] {
        payload.append(contentsOf: value.littleEndianBytes)
    }
    payload.append(contentsOf: UInt32(41).littleEndianBytes)
    payload.append(contentsOf: UInt32(77).littleEndianBytes)
    payload.append(contentsOf: Data("abc".utf8))
    return payload
}

@Test
func decodesAnUnplacedExitedTerminal() throws {
    let data = Data(
        #"""
        {
          "machine":{"id":"machine_11111111111111111111111111111111"},
          "session":{"id":"session_22222222222222222222222222222222","name":"demo"},
          "workspaces":[],"screens":[],"panes":[],"tabs":[],
          "terminals":[{
            "id":"term_88888888888888888888888888888888",
            "tab_id":null,"title":"","cols":80,"rows":24,
            "running":false,"lifecycle":"exited"
          }],
          "browsers":[],
          "cursor":{"generation":"g","revision":"9"}
        }
        """#.utf8
    )

    let snapshot = try JSONDecoder().decode(ResourceSnapshot.self, from: data)
    let terminal = try #require(snapshot.terminals.first)
    #expect(terminal.tabID == nil)
    #expect(terminal.lifecycle == "exited")
}

@Test
func decodesEveryNativeLayoutShape() async throws {
    let data = Data(
        #"""
        {
          "machine":{"id":"machine_11111111111111111111111111111111"},
          "session":{"id":"session_22222222222222222222222222222222","name":"demo"},
          "workspaces":[{"id":"ws_33333333333333333333333333333333","name":"agents","index":0,"focused":true}],
          "screens":[{
            "id":"screen_44444444444444444444444444444444",
            "workspace_id":"ws_33333333333333333333333333333333",
            "name":"main","index":0,"focused":true,
            "layout":{
              "version":1,
              "screen_id":"screen_44444444444444444444444444444444",
              "active_pane_id":"pane_55555555555555555555555555555555",
              "zoomed_pane_id":null,
              "root":{"kind":"viewport","base_width":0.5,"columns":[
                {"column_id":"column_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","width":0.5,"root":{
                  "kind":"split","split_id":"split_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "direction":"horizontal","ratio":0.6,
                  "first":{"kind":"leaf","pane_id":"pane_55555555555555555555555555555555","tab_ids":["tab_77777777777777777777777777777777"],"active_tab_id":"tab_77777777777777777777777777777777"},
                  "second":{"kind":"stack","pane_ids":["pane_66666666666666666666666666666666"],"expanded_pane_id":"pane_66666666666666666666666666666666"}
                }}
              ]}
            }
          }],
          "panes":[
            {"id":"pane_55555555555555555555555555555555","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":true,"zoomed":false},
            {"id":"pane_66666666666666666666666666666666","screen_id":"screen_44444444444444444444444444444444","name":null,"focused":false,"zoomed":false}
          ],
          "tabs":[
            {"id":"tab_77777777777777777777777777777777","pane_id":"pane_55555555555555555555555555555555","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"term_88888888888888888888888888888888"},
            {"id":"tab_99999999999999999999999999999999","pane_id":"pane_66666666666666666666666666666666","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"term_88888888888888888888888888888888"}
          ],
          "terminals":[{"id":"term_88888888888888888888888888888888","tab_id":"tab_77777777777777777777777777777777","title":"shell","cols":80,"rows":24,"running":true,"lifecycle":"running"}],
          "browsers":[],
          "cursor":{"generation":"g","revision":"8"}
        }
        """#.utf8
    )

    var snapshot = try JSONDecoder().decode(ResourceSnapshot.self, from: data)
    #expect(snapshot.workspaces.first?.name == "agents")
    #expect(snapshot.screenCount(in: "ws_33333333333333333333333333333333") == 1)
    #expect(snapshot.screenCount(in: "ws_missing") == 0)
    #expect(snapshot.screens.first?.layout.root.paneIDs.count == 2)
    guard case .viewport(let baseWidth, let columns) = snapshot.screens[0].layout.root else {
        Issue.record("viewport root was not decoded")
        return
    }
    #expect(baseWidth == 0.5)
    #expect(columns.count == 1)
    guard case .split(_, .horizontal, let ratio, _, let second) = columns[0].root else {
        Issue.record("split column was not decoded")
        return
    }
    #expect(ratio == 0.6)
    guard case .stack(let panes, let expanded) = second else {
        Issue.record("stack child was not decoded")
        return
    }
    #expect(panes == [expanded])
    #expect(snapshot.visibleTerminalPlacements(in: snapshot.screens[0]) == [
        "pane_55555555555555555555555555555555": "term_88888888888888888888888888888888",
        "pane_66666666666666666666666666666666": "term_88888888888888888888888888888888",
    ])

    let deltaData = Data(
        #"""
        {"item":{"kind":"delta","previous_revision":"8","revision":"9","changes":[
          {"kind":"upsert","sequence":1,"resource":"terminal","id":"term_88888888888888888888888888888888","value":{"id":"term_88888888888888888888888888888888","tab_id":"tab_77777777777777777777777777777777","title":"updated","cols":80,"rows":24,"running":true,"lifecycle":"running"}},
          {"kind":"upsert","sequence":2,"resource":"pane","id":"pane_55555555555555555555555555555555","value":{"id":"pane_55555555555555555555555555555555","screen_id":"screen_44444444444444444444444444444444","name":"renamed","focused":true,"zoomed":false}},
          {"kind":"upsert","sequence":3,"resource":"notification","id":"notification_99999999999999999999999999999999","value":{"id":"notification_99999999999999999999999999999999","message":"ignored"}}
        ]}}
        """#.utf8
    )
    let decodedResult = await FrontendResourceDecoder().decode([deltaData])
    let decoded = try #require(decodedResult)
    guard decoded.count == 1, case .delta(let delta) = decoded[0] else {
        Issue.record("typed resource delta was not decoded")
        return
    }
    #expect(delta.previousRevision == "8")
    #expect(delta.revision == "9")
    #expect(delta.changes.count == 3)

    var sawTitle = false
    var sawTopology = false
    for change in delta.changes {
        let appliedChange = snapshot.apply(change)
        switch try #require(appliedChange) {
        case .terminalTitle(let id, let title):
            sawTitle = id == "term_88888888888888888888888888888888"
                && title == "updated"
        case .changed(let impact):
            sawTopology = impact.contains(.topology)
        case .ignored:
            break
        }
    }
    snapshot.setRevision(delta.revision)
    #expect(sawTitle)
    #expect(sawTopology)
    #expect(
        snapshot.pane("pane_55555555555555555555555555555555")?
            .displayName(localization: testLocalization) == "renamed"
    )
    #expect(snapshot.cursor.revision == "9")
}

@Test
func remoteIdentitySelectionFailsClosedUnlessExactlyOneItemExists() {
    let first = ResourceIdentity(id: "machine-a", name: "A")
    let second = ResourceIdentity(id: "machine-b", name: "B")

    #expect(uniqueFrontendIdentity([]) == nil)
    #expect(uniqueFrontendIdentity([first])?.id == first.id)
    #expect(uniqueFrontendIdentity([first, second]) == nil)
}

@Test
func remoteLayoutNumbersRejectCrashableAndOutOfProtocolValues() {
    let unsafeColumn = Data(
        #"{"column_id":"column-a","width":1e308,"root":{"kind":"leaf","pane_id":"pane-a","tab_ids":[],"active_tab_id":null}}"#.utf8
    )
    let unsafeSplit = Data(
        #"{"kind":"split","split_id":"split-a","direction":"horizontal","ratio":1e308,"first":{"kind":"leaf","pane_id":"pane-a","tab_ids":[],"active_tab_id":null},"second":{"kind":"leaf","pane_id":"pane-b","tab_ids":[],"active_tab_id":null}}"#.utf8
    )
    let unsafeWorkspaceIndex = Data(
        #"{"id":"workspace-a","name":"","index":4294967295,"focused":true}"#.utf8
    )
    let unsafeTabIndex = Data(
        #"{"id":"tab-a","pane_id":"pane-a","name":null,"index":4294967295,"focused":true,"content_kind":"terminal","content_id":"terminal-a"}"#.utf8
    )

    #expect((try? JSONDecoder().decode(ViewportColumn.self, from: unsafeColumn)) == nil)
    #expect((try? JSONDecoder().decode(LayoutNode.self, from: unsafeSplit)) == nil)
    #expect((try? JSONDecoder().decode(WorkspaceSnapshot.self, from: unsafeWorkspaceIndex)) == nil)
    #expect((try? JSONDecoder().decode(TabSnapshot.self, from: unsafeTabIndex)) == nil)
}

@Test
func visibleLayoutPanesExcludeCollapsedStackMembersAndHonorZoom() {
    let stack = LayoutNode.stack(
        paneIDs: ["pane-a", "pane-b", "pane-c"],
        expandedPaneID: "pane-b"
    )
    let split = LayoutNode.split(
        splitID: "split",
        direction: .horizontal,
        ratio: 0.5,
        first: .leaf(paneID: "pane-visible", tabIDs: [], activeTabID: nil),
        second: stack
    )
    #expect(split.paneIDs == ["pane-visible", "pane-a", "pane-b", "pane-c"])
    #expect(split.visiblePaneIDs == ["pane-visible", "pane-b"])

    let layout = LayoutDocument(
        version: 1,
        screenID: "screen",
        activePaneID: "pane-c",
        zoomedPaneID: "pane-c",
        root: split
    )
    #expect(layout.visiblePaneIDs == ["pane-c"])
}

@Test
func resourceParametersPreserveMixedJSONTypes() throws {
    let encoded = try [
        "direction": JSONValue.string("right"),
        "viewport_width": .number(0.55),
        "columns": .integer(72),
        "enabled": .bool(true),
    ].encodedJSON()
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
    )
    #expect(object["direction"] as? String == "right")
    #expect(object["viewport_width"] as? Double == 0.55)
    #expect(object["columns"] as? Int == 72)
    #expect(object["enabled"] as? Bool == true)
}

@Test
func terminalGeometryIsBoundedAndNonzero() {
    #expect(terminalGeometry(width: 0, height: 0) == TerminalGeometry(cols: 1, rows: 1))
    #expect(terminalGeometry(width: 856, height: 424) == TerminalGeometry(cols: 100, rows: 24))
}

@Test
func markedTextRangesUseOneUTF16CoordinateSpace() {
    let unavailable = NSRange(location: NSNotFound, length: 0)
    let initial = MarkedTextRanges.updated(
        textLength: ("かな" as NSString).length,
        selectedRange: NSRange(location: 1, length: 1),
        replacementRange: unavailable,
        currentMarkedRange: unavailable,
        fallbackSelection: NSRange(location: 0, length: 0)
    )
    #expect(initial.marked == NSRange(location: 0, length: 2))
    #expect(initial.selected == NSRange(location: 1, length: 1))

    let replaced = MarkedTextRanges.updated(
        textLength: ("日本語" as NSString).length,
        selectedRange: NSRange(location: 2, length: 1),
        replacementRange: NSRange(location: 20, length: 2),
        currentMarkedRange: initial.marked,
        fallbackSelection: unavailable
    )
    #expect(replaced.marked == NSRange(location: 20, length: 3))
    #expect(replaced.selected == NSRange(location: 22, length: 1))
}

@Test
func terminalHandleFFIQueuePreservesFIFOAndDisconnectDrain() async {
    let executor = SerialFFIExecutor(label: "test.native-terminal.fifo")
    let started = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let order = EventLog()
    let first = Task {
        await executor.run {
            order.append("send")
            started.continuation.yield()
            release.wait()
            return true
        }
    }
    for await _ in started.stream { break }
    #expect(order.snapshot == ["send"])
    let readEnqueued = AsyncStream<Void>.makeStream()
    let read = Task {
        await executor.run({ order.append("read"); return true }, onEnqueued: { readEnqueued.continuation.yield() })
    }
    for await _ in readEnqueued.stream { break }
    let removeEnqueued = AsyncStream<Void>.makeStream()
    let removeCallback = Task {
        await executor.run({ order.append("callback-removal"); return true }, onEnqueued: { removeEnqueued.continuation.yield() })
    }
    for await _ in removeEnqueued.stream { break }
    let disconnectEnqueued = AsyncStream<Void>.makeStream()
    let disconnect = Task {
        await executor.run({ order.append("disconnect"); return true }, onEnqueued: { disconnectEnqueued.continuation.yield() })
    }
    for await _ in disconnectEnqueued.stream { break }
    #expect(order.snapshot == ["send"])
    release.signal()
    _ = await first.value
    _ = await read.value
    _ = await removeCallback.value
    _ = await disconnect.value
    #expect(order.snapshot == ["send", "read", "callback-removal", "disconnect"])
}

@Test
func canceledQueuedFFIOperationDoesNotExecute() async throws {
    let executor = SerialFFIExecutor(label: "test.native-terminal.cancel")
    let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let releaseFirst = DispatchSemaphore(value: 0)
    let first = Task {
        await executor.run {
            firstStarted.continuation.yield()
            releaseFirst.wait()
            return true
        }
    }
    for await _ in firstStarted.stream { break }

    let queued = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let operations = EventLog()
    let cancellation = FFICancellation {}
    let second = Task {
        try await executor.runCancellable(
            cancellation: cancellation,
            { operations.append("canceled"); return true },
            onEnqueued: { queued.continuation.yield() }
        )
    }
    for await _ in queued.stream { break }
    second.cancel()
    releaseFirst.signal()

    _ = await first.value
    do {
        _ = try await second.value
        Issue.record("A canceled queued operation returned a value.")
    } catch is CancellationError {
    } catch {
        Issue.record("A canceled queued operation returned an unexpected error: \(error)")
    }
    firstStarted.continuation.finish()
    queued.continuation.finish()
    #expect(operations.snapshot.isEmpty)
}

@Test
func queuedFFIOperationDeadlineIncludesTimeBeforeExecution() async throws {
    let executor = SerialFFIExecutor(
        label: "test.native-terminal.queue-deadline",
        timeoutScheduler: { _, action in Task { await action() } }
    )
    let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let releaseFirst = DispatchSemaphore(value: 0)
    let first = Task {
        await executor.run {
            firstStarted.continuation.yield()
            releaseFirst.wait()
            return true
        }
    }
    for await _ in firstStarted.stream { break }

    let operations = EventLog()
    let cancellation = FFICancellation { operations.append("cancel") }
    do {
        _ = try await executor.runCancellable(
            cancellation: cancellation,
            timeoutNanoseconds: 10_000_000
        ) {
            operations.append("execute")
            return true
        }
        Issue.record("A timed-out queued operation returned a value.")
    } catch SerialFFIExecutorError.timedOut {
    } catch {
        Issue.record("A timed-out queued operation returned an unexpected error: \(error)")
    }

    #expect(operations.snapshot == ["cancel"])
    releaseFirst.signal()
    _ = await first.value
    firstStarted.continuation.finish()
    #expect(operations.snapshot == ["cancel"])
}

@Test
func completedFFIOperationCancelsPendingDeadline() async throws {
    let deadlineHold = AsyncStream<Void>.makeStream()
    let deadlineCancelled = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let executor = SerialFFIExecutor(
        label: "test.native-terminal.completed-deadline",
        timeoutScheduler: { _, _ in
            Task {
                await withTaskCancellationHandler {
                    for await _ in deadlineHold.stream {}
                } onCancel: {
                    deadlineCancelled.continuation.yield()
                }
            }
        }
    )

    let result = try await executor.runCancellable(
        cancellation: FFICancellation {},
        timeoutNanoseconds: 15_000_000_000
    ) {
        true
    }

    #expect(result == true)
    for await _ in deadlineCancelled.stream { break }
    deadlineHold.continuation.finish()
    deadlineCancelled.continuation.finish()
}

@Test
func serialFFIExecutorBoundsActiveAndQueuedCancellableWork() async throws {
    let executor = SerialFFIExecutor(
        label: "test.native-terminal.queue-bound",
        maximumPendingCancellableOperations: 1
    )
    let firstStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let releaseFirst = DispatchSemaphore(value: 0)
    let first = Task {
        try await executor.runCancellable(cancellation: FFICancellation {}) {
            firstStarted.continuation.yield()
            releaseFirst.wait()
            return true
        }
    }
    for await _ in firstStarted.stream { break }

    do {
        _ = try await executor.runCancellable(cancellation: FFICancellation {}) { true }
        Issue.record("The bounded serial executor accepted too much work.")
    } catch SerialFFIExecutorError.queueFull {
    } catch {
        Issue.record("The bounded serial executor returned an unexpected error: \(error)")
    }

    releaseFirst.signal()
    let firstResult = try await first.value
    #expect(firstResult == true)
    firstStarted.continuation.finish()
}

@Test
func canceledAttachedTerminalIsDisconnectedBeforeOwnershipIsLost() async {
    let operations = EventLog()
    do {
        _ = try await FrontendService.transferAttachedTerminal(
            42,
            cancellationRequested: true
        ) { address in
            operations.append("disconnect:\(address)")
        }
        Issue.record("A canceled terminal attach transferred ownership.")
    } catch is CancellationError {
        #expect(operations.snapshot == ["disconnect:42"])
    } catch {
        Issue.record("A canceled terminal attach returned an unexpected error: \(error)")
    }
}

@Test
func resizeQueueKeepsOnlyNewestPendingGeometry() {
    var queue = NewestResizeQueue()
    let firstStarts = queue.submit(TerminalGeometry(cols: 80, rows: 24))
    #expect(firstStarts)
    #expect(queue.take() == TerminalGeometry(cols: 80, rows: 24))
    let secondStarts = queue.submit(TerminalGeometry(cols: 100, rows: 30))
    #expect(secondStarts)
    let thirdStarts = queue.submit(TerminalGeometry(cols: 120, rows: 40))
    #expect(!thirdStarts)
    #expect(queue.take() == TerminalGeometry(cols: 120, rows: 40))
    #expect(queue.take() == nil)
}

@Test
func closedTerminalConnectionRequiresExplicitReattach() {
    #expect(terminalAttachmentDisposition(didExit: false, connectionClosed: false) == .active)
    #expect(terminalAttachmentDisposition(didExit: true, connectionClosed: true) == .exited)
    #expect(
        terminalAttachmentDisposition(didExit: false, connectionClosed: true)
            == .reconnectRequired
    )
}

@Test
func focusMutationTrackerRejectsStaleRollback() {
    var tracker = FocusMutationTracker()
    let first = tracker.begin(workspaceID: nil, screenID: nil)
    let second = tracker.begin(workspaceID: "workspace-a", screenID: "screen-a")

    let staleFinish = tracker.finish(first)
    #expect(!staleFinish)
    #expect(tracker.owns(second))
    let staleRollback = tracker.rollback(first)
    #expect(staleRollback == nil)
    let rollback = tracker.rollback(second)
    #expect(rollback?.workspaceID == "workspace-a")
    #expect(rollback?.screenID == "screen-a")
}

@Test
func focusMutationAdmissionWaitsForControllerRetirement() {
    #expect(frontendFocusMutationIsAdmitted(
        pendingMutations: 0,
        pendingRetirements: 0,
        maximumPendingMutations: 16
    ))
    #expect(!frontendFocusMutationIsAdmitted(
        pendingMutations: 16,
        pendingRetirements: 0,
        maximumPendingMutations: 16
    ))
    #expect(!frontendFocusMutationIsAdmitted(
        pendingMutations: 0,
        pendingRetirements: 1,
        maximumPendingMutations: 16
    ))
}

@Test @MainActor
func terminalTitleLookupStreamsOnlyTheSelectedOwner() async throws {
    let selected = TerminalTitleOwner(terminalID: "terminal-a", title: "before")
    let unrelated = TerminalTitleOwner(terminalID: "terminal-b", title: "other")
    let lookup = TerminalTitleFn(owners: [
        selected.terminalID: selected,
        unrelated.terminalID: unrelated,
    ])
    let subscription = try #require(lookup("terminal-a"))

    unrelated.replace(with: "not-selected")
    selected.replace(with: "after")
    var updates = subscription.updates.makeAsyncIterator()

    #expect(subscription.current == "before")
    #expect(await updates.next() == "after")
    #expect(lookup("terminal-missing") == nil)
    selected.cancel()
    unrelated.cancel()
}

@Test
func resourceGenerationRejectsAReplyAfterStreamStateAdvances() {
    var generation = FrontendResourceGeneration()
    let requestGeneration = generation.token

    generation.advance()

    #expect(!generation.matches(requestGeneration))
    #expect(generation.matches(generation.token))
}

@Test
func resourceRecoveryPolicyHasABoundedExponentialBackoff() {
    let policy = FrontendRecoveryPolicy(
        maximumAttempts: 3,
        initialBackoffNanoseconds: 100
    )

    #expect(policy.maximumAttempts == 3)
    #expect(policy.backoffNanoseconds(afterFailedAttempt: 0) == 100)
    #expect(policy.backoffNanoseconds(afterFailedAttempt: 1) == 200)
    #expect(policy.backoffNanoseconds(afterFailedAttempt: 2) == 400)
    #expect(policy.backoffNanoseconds(forRecoveryAttempt: 0) == 100)
    #expect(policy.backoffNanoseconds(forRecoveryAttempt: 1) == 200)
    #expect(policy.backoffNanoseconds(forRecoveryAttempt: 2) == 400)
    #expect(policy.backoffNanoseconds(forRecoveryAttempt: 3) == nil)
}

@Test
func resourceRecoveryBudgetResetsOnlyAfterAStableRepairWindow() {
    var recovery = FrontendRecoveryTracker()
    recovery.recordAttempt()
    recovery.recordSuccessfulRepair(at: 1_000)

    recovery.resetIfStable(now: 1_099, stableWindowNanoseconds: 100)
    #expect(recovery.attempts == 1)

    recovery.resetIfStable(now: 1_100, stableWindowNanoseconds: 100)
    #expect(recovery.attempts == 0)
}

@Test
func resourceRecoveryCancelsTheExactActiveStream() throws {
    let stream = FrontendResourceStream(id: "stream-active")
    let encoded = try stream.cancellationParameters(
        machineID: "machine-a",
        sessionID: "session-a"
    ).encodedJSON()
    let parameters = try #require(
        JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: String]
    )

    #expect(parameters == [
        "machine": "machine-a",
        "session": "session-a",
        "stream": "stream-active",
    ])
}

@Test
func mutationIndeterminateErrorKeepsTheRetryIdentityForReconciliation() {
    let error = FrontendServiceError.requestFailure(#"""
    {
      "code":"mutation.indeterminate",
      "message":"the mutation outcome is unknown",
      "details":{
        "operation":"workspace.create",
        "idempotency_key":"native-test-42"
      }
    }
    """#, localization: testLocalization)

    guard case .mutationIndeterminate(let operation, let idempotencyKey, _) = error else {
        Issue.record("The mutation failure was not classified as indeterminate.")
        return
    }
    #expect(operation == "workspace.create")
    #expect(idempotencyKey == "native-test-42")
    #expect(error.requiresAuthoritativeReconciliation)
}

@Test
func rawServiceFailuresStayOutOfLocalizedUserMessages() {
    let raw = "invitation has no Iroh route"
    let connection = FrontendServiceError.connectionFailure(
        raw,
        localization: testLocalization
    )
    #expect(connection.localizedDescription == testLocalization.text(
        "error.connection_failure",
        "The frontend could not connect. See diagnostics for details."
    ))
    #expect(connection.localizedDescription != raw)
    #expect(connection.diagnosticDescription == raw)

    let request = FrontendServiceError.requestFailure(
        #"{"code":"transport.closed","message":"socket ended"}"#,
        localization: testLocalization
    )
    #expect(request.localizedDescription == testLocalization.text(
        "error.request_failure",
        "The frontend request failed. See diagnostics for details."
    ))
    #expect(request.diagnosticDescription?.contains("socket ended") == true)
}

@Test
func transportDiagnosticsAreDeduplicatedAndBounded() {
    var entries: [String] = []
    for diagnostic in ["first", "second", "third", "second", "123456"] {
        entries = appendingTransportDiagnostic(
            diagnostic,
            to: entries,
            maximumEntries: 3,
            maximumCharacters: 4
        )
    }

    #expect(entries == ["hird", "cond", "3456"])
    #expect(entries.allSatisfy { $0.count <= 4 })
}

@Test
func localizationIsInjectedForTextAndFormatting() {
    let localization = Localization(
        locale: Locale(identifier: "en_US_POSIX"),
        resolve: { key, fallback in "[\(key)] \(fallback)" }
    )

    #expect(localization.text("sample.text", "Fallback") == "[sample.text] Fallback")
    #expect(localization.format("sample.count", "%d items", 3) == "[sample.count] 3 items")
}

@Test @MainActor
func terminalInputRelayReportsBoundedBufferDrops() async {
    let input = AsyncStream<QueuedTerminalInput>.makeStream(
        bufferingPolicy: .bufferingOldest(1)
    )
    let drops = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let relay = GhosttyTerminalInputRelay(
        continuation: input.continuation,
        dropContinuation: drops.continuation
    )
    defer {
        input.continuation.finish()
        drops.continuation.finish()
    }

    #expect(relay.send(Data("first".utf8)))
    #expect(!relay.send(Data("second".utf8)))
    var inputIterator = input.stream.makeAsyncIterator()
    guard let queued = await inputIterator.next(), case .bytes(let received) = queued.input else {
        Issue.record("The relay did not keep the oldest buffered input.")
        return
    }
    #expect(received == Data("first".utf8))
    var dropIterator = drops.stream.makeAsyncIterator()
    let dropSignal: Void? = await dropIterator.next()
    #expect(dropSignal != nil)

    input.continuation.finish()
    #expect(!relay.send(Data("after-finish".utf8)))
}

@Test
func terminalInputRelayStampsTheTransportEpochBeforeQueueing() async {
    let input = AsyncStream<QueuedTerminalInput>.makeStream()
    let drops = AsyncStream<Void>.makeStream()
    let relay = GhosttyTerminalInputRelay(
        continuation: input.continuation,
        dropContinuation: drops.continuation
    )

    relay.beginEpoch(7)
    #expect(relay.send(Data("old".utf8)))
    relay.beginEpoch(8)
    #expect(relay.send(Data("new".utf8)))
    input.continuation.finish()
    var queued = input.stream.makeAsyncIterator()

    #expect(await queued.next()?.epoch == 7)
    #expect(await queued.next()?.epoch == 8)
}

@Test
func resourceDrainUsesTheCDescriptorTwoCallContract() throws {
    var pending = [
        Data(#"{"sequence":1}"#.utf8),
        Data(#"{"sequence":2}"#.utf8),
    ]
    let batch = drainFrontendResourceUpdates { descriptor, buffer, capacity in
        descriptor = CmuxFrontendResourceUpdate()
        descriptor.ended = true
        descriptor.end_reason = FrontendResourceStreamEndReason.gap.rawValue
        guard let payload = pending.first else { return true }
        descriptor.payload_length = payload.count
        guard let buffer, capacity >= payload.count else { return true }
        payload.copyBytes(to: buffer, count: payload.count)
        pending.removeFirst()
        return true
    }

    #expect(batch.ended)
    #expect(batch.endReason == .gap)
    #expect(!batch.overflowed)
    #expect(batch.envelopes.count == 2)
    #expect(!batch.hasMore)
    let sequences = try batch.envelopes.map { payload in
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Int]
        )
        return try #require(object["sequence"])
    }
    #expect(sequences == [1, 2])
}

@Test
func resourceDrainStopsAtTheEnvelopeBudget() {
    var pending = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
    let copy: (inout CmuxFrontendResourceUpdate, UnsafeMutablePointer<UInt8>?, Int) -> Bool = {
        descriptor, buffer, capacity in
        descriptor = CmuxFrontendResourceUpdate()
        guard let payload = pending.first else { return true }
        descriptor.payload_length = payload.count
        guard let buffer, capacity >= payload.count else { return true }
        payload.copyBytes(to: buffer, count: payload.count)
        pending.removeFirst()
        return true
    }

    let first = drainFrontendResourceUpdates(maximumEnvelopes: 2, copy: copy)
    #expect(first.envelopes.count == 2)
    #expect(first.hasMore)
    #expect(pending.count == 1)

    let second = drainFrontendResourceUpdates(maximumEnvelopes: 2, copy: copy)
    #expect(second.envelopes == [Data("three".utf8)])
    #expect(!second.hasMore)
    #expect(pending.isEmpty)
}

@Test
func resourceDrainDefersStreamEndUntilQueuedEnvelopesAreDrained() {
    var pending = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
    let copy: (inout CmuxFrontendResourceUpdate, UnsafeMutablePointer<UInt8>?, Int) -> Bool = {
        descriptor, buffer, capacity in
        descriptor = CmuxFrontendResourceUpdate()
        descriptor.ended = true
        descriptor.end_reason = FrontendResourceStreamEndReason.gap.rawValue
        guard let payload = pending.first else { return true }
        descriptor.payload_length = payload.count
        guard let buffer, capacity >= payload.count else { return true }
        payload.copyBytes(to: buffer, count: payload.count)
        pending.removeFirst()
        return true
    }

    let first = drainFrontendResourceUpdates(maximumEnvelopes: 2, copy: copy)
    #expect(first.envelopes == [Data("one".utf8), Data("two".utf8)])
    #expect(first.hasMore)
    #expect(!first.ended)
    #expect(first.endReason == .none)

    let second = drainFrontendResourceUpdates(maximumEnvelopes: 2, copy: copy)
    #expect(second.envelopes == [Data("three".utf8)])
    #expect(!second.hasMore)
    #expect(second.ended)
    #expect(second.endReason == .gap)
    #expect(pending.isEmpty)
}

@Test
func resourceDrainLeavesTheNextEnvelopeAtTheByteBudget() {
    var pending = [Data("four".utf8), Data("five".utf8)]
    let copy: (inout CmuxFrontendResourceUpdate, UnsafeMutablePointer<UInt8>?, Int) -> Bool = {
        descriptor, buffer, capacity in
        descriptor = CmuxFrontendResourceUpdate()
        guard let payload = pending.first else { return true }
        descriptor.payload_length = payload.count
        guard let buffer, capacity >= payload.count else { return true }
        payload.copyBytes(to: buffer, count: payload.count)
        pending.removeFirst()
        return true
    }

    let first = drainFrontendResourceUpdates(maximumBytes: 6, copy: copy)
    #expect(first.envelopes == [Data("four".utf8)])
    #expect(first.hasMore)
    #expect(pending.count == 1)

    let second = drainFrontendResourceUpdates(maximumBytes: 6, copy: copy)
    #expect(second.envelopes == [Data("five".utf8)])
    #expect(!second.hasMore)
    #expect(pending.isEmpty)
}

@Test
func resourceDrainRejectsOversizedFirstEnvelopeBeforeAllocation() {
    var discarded = false
    var requestedPayloadBuffer = false
    let batch = drainFrontendResourceUpdates(
        maximumBytes: 3,
        maximumEnvelopeBytes: 3,
        discard: { discarded = true },
        copy: { descriptor, buffer, _ in
            descriptor = CmuxFrontendResourceUpdate()
            descriptor.payload_length = 4
            requestedPayloadBuffer = buffer != nil
            return true
        }
    )

    #expect(batch.envelopes.isEmpty)
    #expect(batch.overflowed)
    #expect(!batch.hasMore)
    #expect(discarded)
    #expect(!requestedPayloadBuffer)
}

@Test
func resourceDrainAcceptsOneProtocolEnvelopeAboveTheBatchBudget() {
    var pending = [Data("four".utf8)]
    var discarded = false
    let batch = drainFrontendResourceUpdates(
        maximumBytes: 3,
        maximumEnvelopeBytes: 4,
        discard: { discarded = true },
        copy: { descriptor, buffer, capacity in
            descriptor = CmuxFrontendResourceUpdate()
            guard let payload = pending.first else { return true }
            descriptor.payload_length = payload.count
            guard let buffer, capacity >= payload.count else { return true }
            payload.copyBytes(to: buffer, count: payload.count)
            pending.removeFirst()
            return true
        }
    )

    #expect(batch.envelopes == [Data("four".utf8)])
    #expect(batch.hasMore)
    #expect(!batch.overflowed)
    #expect(!discarded)
    #expect(pending.isEmpty)
}

@Test
func resourceDrainFailsClosedOnCDescriptorOverflow() {
    var reportsOverflow = true
    let batch = drainFrontendResourceUpdates { descriptor, _, _ in
        descriptor = CmuxFrontendResourceUpdate()
        guard reportsOverflow else { return false }
        reportsOverflow = false
        descriptor.overflowed = true
        return true
    }

    #expect(batch.envelopes.isEmpty)
    #expect(batch.overflowed)
    #expect(!batch.ended)
    #expect(batch.endReason == .none)
}

@Test
func resourceDrainTreatsUnknownStreamEndAsTerminalError() {
    let batch = drainFrontendResourceUpdates { descriptor, _, _ in
        descriptor = CmuxFrontendResourceUpdate()
        descriptor.ended = true
        descriptor.end_reason = UInt32.max
        return true
    }

    #expect(batch.ended)
    #expect(batch.endReason == .error)
}

@Test
func renderDrainConsumesUnknownPayloadBeforeContinuing() {
    var pending: [(UInt32, Data)] = [
        (UInt32.max, Data("unknown".utf8)),
        (TerminalRenderEvent.Kind.bytes.rawValue, Data("visible".utf8)),
    ]
    var leased: (UInt32, Data)?
    let copy: (inout CmuxFrontendRenderEvent, UnsafeMutablePointer<UInt8>?, Int) -> Bool = {
        descriptor, buffer, capacity in
        if leased == nil { leased = pending.first }
        guard let current = leased else { return false }
        descriptor = CmuxFrontendRenderEvent()
        descriptor.kind = current.0
        descriptor.cols = 80
        descriptor.rows = 24
        descriptor.input_epoch = 7
        descriptor.payload_length = current.1.count
        guard let buffer, capacity >= current.1.count else { return true }
        current.1.copyBytes(to: buffer, count: current.1.count)
        pending.removeFirst()
        leased = nil
        return true
    }

    let batch = drainTerminalRenderEvents(copy: copy)

    #expect(batch.events.count == 1)
    #expect(batch.events.first?.kind == .bytes)
    #expect(batch.events.first?.payload == Data("visible".utf8))
    #expect(batch.events.first?.inputEpoch == 7)
    #expect(!batch.hasMore)
    #expect(!batch.overflowed)
    #expect(pending.isEmpty)
    #expect(leased == nil)
}

@Test
func renderDrainRejectsOversizedEventBeforeAllocation() {
    var discarded = false
    var requestedPayloadBuffer = false
    let batch = drainTerminalRenderEvents(
        maximumEventBytes: 3,
        maximumBytes: 6,
        discard: { discarded = true },
        copy: { descriptor, buffer, _ in
            descriptor = CmuxFrontendRenderEvent()
            descriptor.kind = TerminalRenderEvent.Kind.bytes.rawValue
            descriptor.payload_length = 4
            requestedPayloadBuffer = buffer != nil
            return true
        }
    )

    #expect(batch.events.isEmpty)
    #expect(!batch.hasMore)
    #expect(batch.overflowed)
    #expect(discarded)
    #expect(!requestedPayloadBuffer)
}

@Test
func renderDrainAcceptsResetAboveFormerFrontendLimit() {
    let formerFrontendLimit = 4 * 1024 * 1024
    let payloadLength = formerFrontendLimit + 1
    var leased = true
    let batch = drainTerminalRenderEvents { descriptor, buffer, capacity in
        guard leased else { return false }
        descriptor = CmuxFrontendRenderEvent()
        descriptor.kind = TerminalRenderEvent.Kind.reset.rawValue
        descriptor.cols = 80
        descriptor.rows = 24
        descriptor.payload_length = payloadLength
        guard let buffer, capacity >= payloadLength else { return true }
        buffer.initialize(repeating: 0, count: payloadLength)
        leased = false
        return true
    }

    #expect(payloadLength < Int(CMUX_TERMINAL_CLIENT_COPY_MAX_BYTES_VALUE))
    #expect(batch.events.count == 1)
    #expect(batch.events.first?.kind == .reset)
    #expect(batch.events.first?.payload.count == payloadLength)
    #expect(!batch.hasMore)
    #expect(!batch.overflowed)
    #expect(!leased)
}

@Test
func renderDrainRejectsByteEventsAboveTheMainActorChunkLimit() {
    var discarded = false
    var requestedPayloadBuffer = false
    let batch = drainTerminalRenderEvents(
        discard: { discarded = true },
        copy: { descriptor, buffer, _ in
            descriptor = CmuxFrontendRenderEvent()
            descriptor.kind = TerminalRenderEvent.Kind.bytes.rawValue
            descriptor.payload_length = 65_537
            requestedPayloadBuffer = buffer != nil
            return true
        }
    )

    #expect(batch.events.isEmpty)
    #expect(batch.overflowed)
    #expect(discarded)
    #expect(!requestedPayloadBuffer)
}

@Test
func renderDrainLeavesTheNextEventAtTheBatchByteBudget() {
    var pending = [Data("four".utf8), Data("five".utf8)]
    var leased: Data?
    let copy: (inout CmuxFrontendRenderEvent, UnsafeMutablePointer<UInt8>?, Int) -> Bool = {
        descriptor, buffer, capacity in
        if leased == nil { leased = pending.first }
        guard let payload = leased else { return false }
        descriptor = CmuxFrontendRenderEvent()
        descriptor.kind = TerminalRenderEvent.Kind.bytes.rawValue
        descriptor.cols = 80
        descriptor.rows = 24
        descriptor.payload_length = payload.count
        guard let buffer, capacity >= payload.count else { return true }
        payload.copyBytes(to: buffer, count: payload.count)
        pending.removeFirst()
        leased = nil
        return true
    }

    let first = drainTerminalRenderEvents(
        maximumEventBytes: 4,
        maximumBytes: 6,
        copy: copy
    )
    #expect(first.events.map(\.payload) == [Data("four".utf8)])
    #expect(first.hasMore)
    #expect(!first.overflowed)
    #expect(pending.count == 1)

    let second = drainTerminalRenderEvents(
        maximumEventBytes: 4,
        maximumBytes: 6,
        copy: copy
    )
    #expect(second.events.map(\.payload) == [Data("five".utf8)])
    #expect(!second.hasMore)
    #expect(!second.overflowed)
    #expect(pending.isEmpty)
}

@Test
func decodesNativeResetSidecarKittyAliasesAndCursors() {
    let payload = nativeResetPayload()
    let metadata = NativeKittyResetMetadata.decode(payload)
    #expect(metadata?.replay == Data("abc".utf8))
    #expect(metadata?.aliases.first?.0 == 41)
    #expect(metadata?.aliases.first?.1 == 77)
    #expect(metadata?.replayNextIDs.0 == 3)
    #expect(metadata?.nextIDs.1 == 6)
}

@Test @MainActor
func resetKeepsSurfaceCreationError() {
    let input = AsyncStream<QueuedTerminalInput>.makeStream()
    let drops = AsyncStream<Void>.makeStream()
    let relay = GhosttyTerminalInputRelay(
        continuation: input.continuation,
        dropContinuation: drops.continuation
    )
    let view = GhosttyRemoteSurfaceView(
        runtime: nil,
        inputRelay: relay,
        localization: testLocalization
    )

    view.apply(TerminalRenderEvent(
        kind: .reset,
        geometry: TerminalGeometry(cols: 80, rows: 24),
        payload: nativeResetPayload()
    ))

    #expect(view.initializationError == testLocalization.text(
        "error.ghostty_runtime",
        "The embedded Ghostty renderer could not start."
    ))
}

@Test @MainActor
func invalidResetBlocksLaterRenderEventsAndReadyState() async {
    let input = AsyncStream<QueuedTerminalInput>.makeStream()
    let drops = AsyncStream<Void>.makeStream()
    let relay = GhosttyTerminalInputRelay(
        continuation: input.continuation,
        dropContinuation: drops.continuation
    )
    let view = GhosttyRemoteSurfaceView(
        runtime: nil,
        inputRelay: relay,
        localization: testLocalization
    )
    let geometry = TerminalGeometry(cols: 80, rows: 24)

    view.setMarkedText(
        "old",
        selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    #expect(view.hasMarkedText())

    view.apply(TerminalRenderEvent(
        kind: .reset,
        geometry: geometry,
        payload: Data("invalid".utf8)
    ))
    view.apply(TerminalRenderEvent(
        kind: .bytes,
        geometry: geometry,
        payload: Data("stale".utf8)
    ))
    view.apply(TerminalRenderEvent(kind: .ready, geometry: geometry, payload: Data()))
    #expect(relay.send(Data("rejected".utf8)))
    input.continuation.finish()
    var queuedInput = input.stream.makeAsyncIterator()

    #expect(!view.renderStreamValid)
    #expect(!view.hasMarkedText())
    #expect(view.markedRange().location == NSNotFound)
    guard let failedInput = await queuedInput.next() else {
        Issue.record("Invalid reset did not fence terminal input.")
        return
    }
    #expect(failedInput.epoch == 0)
    #expect(view.initializationError == testLocalization.text(
        "error.terminal_snapshot",
        "The terminal snapshot was invalid."
    ))
}

@Test @MainActor
func exitClearsMarkedTextFromThePreviousInputEpoch() async {
    let input = AsyncStream<QueuedTerminalInput>.makeStream()
    let drops = AsyncStream<Void>.makeStream()
    let relay = GhosttyTerminalInputRelay(
        continuation: input.continuation,
        dropContinuation: drops.continuation
    )
    let view = GhosttyRemoteSurfaceView(
        runtime: nil,
        inputRelay: relay,
        localization: testLocalization
    )

    view.setMarkedText(
        "old",
        selectedRange: NSRange(location: 3, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    view.apply(TerminalRenderEvent(
        kind: .exit,
        geometry: TerminalGeometry(cols: 80, rows: 24),
        payload: Data(),
        inputEpoch: 7
    ))
    #expect(relay.send(Data("after-exit".utf8)))
    input.continuation.finish()
    var queuedInput = input.stream.makeAsyncIterator()

    #expect(!view.hasMarkedText())
    #expect(view.markedRange().location == NSNotFound)
    guard let exitInput = await queuedInput.next() else {
        Issue.record("Exit did not fence terminal input.")
        return
    }
    #expect(exitInput.epoch == 7)
}

@Test
func sideBySideLayoutUsesScreenRelativeGhosttyCoordinates() {
    let visibleFrame = CGRect(x: 1440, y: 25, width: 1728, height: 971)
    let layout = SideBySideWindowLayout.fit(visibleFrame: visibleFrame)
    let primaryScreenLayout = SideBySideWindowLayout.fit(
        visibleFrame: CGRect(origin: CGPoint(x: 0, y: 25), size: visibleFrame.size)
    )

    #expect(layout.nativeFrame.minX == visibleFrame.minX)
    #expect(layout.nativeFrame.minY == visibleFrame.minY)
    #expect(layout.nativeFrame.height == visibleFrame.height)
    #expect(layout.nativeFrame.width > 900)
    #expect(layout.ghosttyPlacement == primaryScreenLayout.ghosttyPlacement)
    #expect(layout.ghosttyPlacement.x > Int(layout.nativeFrame.width))
    #expect(layout.ghosttyPlacement.y == 0)
    #expect(layout.ghosttyPlacement.columns >= 80)
    #expect(layout.ghosttyPlacement.rows >= 40)
}

@Test
func modifierTransitionsUseTheChangedPhysicalKey() {
    let cases: [(UInt16, UInt16, UInt, UInt)] = [
        (0x38, 0x3C, UInt(NX_DEVICELSHIFTKEYMASK), UInt(NX_DEVICERSHIFTKEYMASK)),
        (0x3B, 0x3E, UInt(NX_DEVICELCTLKEYMASK), UInt(NX_DEVICERCTLKEYMASK)),
        (0x3A, 0x3D, UInt(NX_DEVICELALTKEYMASK), UInt(NX_DEVICERALTKEYMASK)),
        (0x37, 0x36, UInt(NX_DEVICELCMDKEYMASK), UInt(NX_DEVICERCMDKEYMASK)),
    ]

    for (leftKey, rightKey, leftMask, rightMask) in cases {
        let bothPressed = NSEvent.ModifierFlags(rawValue: leftMask | rightMask)
        #expect(nativeModifierKeyIsPressed(keyCode: leftKey, modifierFlags: bothPressed) == true)
        #expect(nativeModifierKeyIsPressed(keyCode: rightKey, modifierFlags: bothPressed) == true)

        let leftOnly = NSEvent.ModifierFlags(rawValue: leftMask)
        #expect(nativeModifierKeyIsPressed(keyCode: leftKey, modifierFlags: leftOnly) == true)
        #expect(nativeModifierKeyIsPressed(keyCode: rightKey, modifierFlags: leftOnly) == false)
    }
}

@Test
func surfaceFocusRequiresActiveApplicationKeyWindowAndFirstResponder() {
    #expect(nativeSurfaceShouldHaveFocus(
        applicationActive: true,
        windowKey: true,
        firstResponder: true
    ))
    #expect(!nativeSurfaceShouldHaveFocus(
        applicationActive: false,
        windowKey: true,
        firstResponder: true
    ))
    #expect(!nativeSurfaceShouldHaveFocus(
        applicationActive: true,
        windowKey: false,
        firstResponder: true
    ))
    #expect(!nativeSurfaceShouldHaveFocus(
        applicationActive: true,
        windowKey: true,
        firstResponder: false
    ))
}

@Test
func connectionAdmissionBlocksCleanupOverlap() {
    #expect(frontendConnectionIsAdmitted(
        isConnecting: false,
        isDisconnecting: false,
        isShuttingDown: false
    ))
    #expect(!frontendConnectionIsAdmitted(
        isConnecting: false,
        isDisconnecting: true,
        isShuttingDown: false
    ))
}

@Test @MainActor
func ghosttyApplicationFocusFollowsActivationNotifications() {
    let center = NotificationCenter()
    var states: [Bool] = []
    let observer = NativeGhosttyApplicationFocusObserver(
        notificationCenter: center,
        initiallyActive: false,
        setFocus: { states.append($0) }
    )

    center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    center.post(name: NSApplication.didResignActiveNotification, object: nil)

    #expect(states == [false, true, false])
    withExtendedLifetime(observer) {}
}

@Test @MainActor
func ghosttyConfigurationLoaderLeavesTheMainThread() async {
    let events = EventLog()

    let value = await loadNativeGhosttyConfiguration {
        events.append(Thread.isMainThread ? "main" : "worker")
        return 42
    }

    #expect(value == 42)
    #expect(events.snapshot == ["worker"])
}

@Test @MainActor
func windowPlacementUsesItsOwnedWindowAndInjectedWriter() throws {
    let visibleFrame = CGRect(x: 1440, y: 25, width: 1728, height: 971)
    let target = TestDemoWindowPlacementWindow(visibleFrame: visibleFrame)
    var writtenData: Data?
    var writtenURL: URL?
    let placement = DemoWindowPlacement(
        windowProvider: { target },
        writeData: { data, url in
            writtenData = data
            writtenURL = url
        }
    )

    placement.applyIfConfigured(environment: [
        "CMUX_NATIVE_WINDOW_LAYOUT_FILE": "/tmp/native-layout.json"
    ])

    let layout = SideBySideWindowLayout.fit(visibleFrame: visibleFrame)
    #expect(target.appliedFrame == layout.nativeFrame)
    #expect(writtenURL?.path == "/tmp/native-layout.json")
    let data = try #require(writtenData)
    #expect(try JSONDecoder().decode(GhosttyWindowPlacement.self, from: data) == layout.ghosttyPlacement)
}

@Test
func ghosttyLauncherRunsExactCmuxBinaryByName() throws {
    let packageDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let launcher = packageDirectory.appendingPathComponent("launch-ghostty-client.sh")
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-native-ghostty-launch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fakeGhostty = temporaryDirectory
        .appendingPathComponent("Ghostty.app/Contents/MacOS/ghostty")
    let fakeCmux = temporaryDirectory.appendingPathComponent("exact-bin/cmux-tui")
    let output = temporaryDirectory.appendingPathComponent("arguments.txt")
    try FileManager.default.createDirectory(
        at: fakeGhostty.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: fakeCmux.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try #"""
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GHOSTTY_MAC_LAUNCH_SOURCE:-}" == "cli" ]]
    while [[ $# -gt 0 && "$1" != "-e" ]]; do shift; done
    [[ "${1:-}" == "-e" ]]
    shift
    [[ "${1:-}" == "cmux-tui" ]]
    command_name="$1"
    shift
    "$command_name" "$@"
    """#.write(to: fakeGhostty, atomically: true, encoding: .utf8)
    try #"""
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' "$@" > "${CMUX_GHOSTTY_LAUNCH_TEST_OUTPUT:?}"
    """#.write(to: fakeCmux, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fakeGhostty.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fakeCmux.path
    )

    let process = Process()
    process.executableURL = launcher
    process.arguments = [
        temporaryDirectory.appendingPathComponent("Ghostty.app").path,
        fakeCmux.path,
        "--title=launcher test",
        "--",
        "--probe",
        "alpha beta",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CMUX_GHOSTTY_LAUNCH_TEST_OUTPUT"] = output.path
    process.environment = environment
    let standardError = Pipe()
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()

    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData, as: UTF8.self)
    #expect(process.terminationStatus == 0, "launcher failed: \(errorText)")
    let arguments = try String(contentsOf: output, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(arguments == ["--probe", "alpha beta"])
}

@Test @MainActor
func appDelegateCreatesAndOwnsInitialWindow() throws {
    let model = FrontendModel(configuration: DemoLaunchConfiguration(
        invitation: "",
        autoConnect: false
    ))
    let delegate = NativeMuxDemoAppDelegate(model: model)
    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    let window = try #require(delegate.window)
    defer { window.close() }

    #expect(window.isVisible)
    #expect(window.delegate === delegate)
    #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
}
