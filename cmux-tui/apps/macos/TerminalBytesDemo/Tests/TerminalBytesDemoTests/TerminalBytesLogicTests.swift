import AppKit
import Foundation
import Observation
import Testing

@testable import TerminalBytesDemo

private final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generationStorage: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationStorage
    }

    func signal() {
        lock.lock()
        generationStorage &+= 1
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in ready {
            continuation.resume()
        }
    }

    func wait(after observedGeneration: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if generationStorage != observedGeneration {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class ManualTerminalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Duration = .zero
    private let ticks: AsyncStream<Void>
    private let tickContinuation: AsyncStream<Void>.Continuation
    private let sleepRequests: AsyncStream<Duration>
    private let requestContinuation: AsyncStream<Duration>.Continuation

    init() {
        let tickEvents = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        ticks = tickEvents.stream
        tickContinuation = tickEvents.continuation
        let requests = AsyncStream.makeStream(
            of: Duration.self,
            bufferingPolicy: .unbounded
        )
        sleepRequests = requests.stream
        requestContinuation = requests.continuation
    }

    var clock: TerminalModelClock {
        TerminalModelClock(
            now: { [self] in now },
            sleepUntil: { [self] deadline, _ in
                try await sleep(until: deadline)
            }
        )
    }

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func advance(by duration: Duration) {
        lock.lock()
        time += duration
        lock.unlock()
        tickContinuation.yield()
    }

    func nextSleepDeadline() async -> Duration {
        for await deadline in sleepRequests {
            return deadline
        }
        Issue.record("The manual clock stopped before receiving a sleep request.")
        return .zero
    }

    private func sleep(until deadline: Duration) async throws {
        requestContinuation.yield(deadline)
        var iterator = ticks.makeAsyncIterator()
        while now < deadline {
            guard await iterator.next() != nil else {
                try Task.checkCancellation()
                throw CancellationError()
            }
            try Task.checkCancellation()
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    // NSLock protects every access to storage, including calls from injected
    // C-operation closures that the compiler must treat as concurrent.
    private let lock = NSLock()
    private let signal = TestSignal()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
        signal.signal()
    }

    func waitUntilSet() async {
        while !value {
            let generation = signal.generation
            if value { return }
            await signal.wait(after: generation)
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    // NSLock protects every access from injected concurrent client operations.
    private let lock = NSLock()
    private let signal = TestSignal()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
        signal.signal()
    }

    func wait(until predicate: @Sendable (Int) -> Bool) async {
        while !predicate(value) {
            let generation = signal.generation
            if predicate(value) { return }
            await signal.wait(after: generation)
        }
    }
}

private final class LockedInputs: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = TestSignal()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func record(_ value: String) -> Int {
        lock.lock()
        storage.append(value)
        let count = storage.count
        lock.unlock()
        signal.signal()
        return count
    }

    func wait(until predicate: @Sendable ([String]) -> Bool) async {
        while !predicate(values) {
            let generation = signal.generation
            if predicate(values) { return }
            await signal.wait(after: generation)
        }
    }
}

@MainActor
private func makeBlockingInputHarness() -> (
    model: TerminalModel,
    firstStarted: LockedFlag,
    releaseFirst: DispatchSemaphore
) {
    let firstStarted = LockedFlag()
    let calls = LockedCounter()
    let releaseFirst = DispatchSemaphore(value: 0)
    let handle = TerminalClientHandle(
        rawAddress: 8,
        attachClient: { _, _, _, _, _ in true },
        destroyClient: { _ in },
        detachClient: { _ in },
        setUpdateCallback: { _, _, _ in },
        sendClient: { _, _, _ in
            calls.increment()
            if calls.value == 1 {
                firstStarted.set()
                releaseFirst.wait()
            }
            return true
        },
        copyFrameClient: { _, _, _ in 0 },
        copyDiagnosticsClient: { _, _, _ in 0 }
    )
    let model = TerminalModel(
        configuration: DemoLaunchConfiguration(
            invitation: "",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            autoConnect: false
        ),
        retainedClient: handle,
        initiallyConnected: true
    )
    return (model, firstStarted, releaseFirst)
}

private final class LockedClientCalls: @unchecked Sendable {
    // NSLock protects all mutable storage. Pointers are recorded as integer
    // addresses so snapshots only contain Sendable values.
    private let lock = NSLock()
    private var attachedStorage: [UInt] = []
    private var attachedTerminalStorage: [String] = []
    private var detachedStorage: [UInt] = []
    private var destroyedStorage: [UInt] = []
    private var updateRegistrationStorage: [Bool] = []

    var attached: [UInt] { snapshot(\.attached) }
    var attachedTerminals: [String] { snapshot(\.attachedTerminals) }
    var detached: [UInt] { snapshot(\.detached) }
    var destroyed: [UInt] { snapshot(\.destroyed) }
    var updateRegistrations: [Bool] { snapshot(\.updateRegistrations) }

    func recordAttach(client: OpaquePointer, terminal: String) {
        lock.lock()
        attachedStorage.append(UInt(bitPattern: client))
        attachedTerminalStorage.append(terminal)
        lock.unlock()
    }

    func recordDetach(_ client: OpaquePointer) {
        lock.lock()
        detachedStorage.append(UInt(bitPattern: client))
        lock.unlock()
    }

    func recordDestroy(_ client: OpaquePointer) {
        lock.lock()
        destroyedStorage.append(UInt(bitPattern: client))
        lock.unlock()
    }

    func recordUpdateRegistration(_ isRegistered: Bool) {
        lock.lock()
        updateRegistrationStorage.append(isRegistered)
        lock.unlock()
    }

    private func snapshot<Value: Sendable>(
        _ keyPath: KeyPath<(
            attached: [UInt],
            attachedTerminals: [String],
            detached: [UInt],
            destroyed: [UInt],
            updateRegistrations: [Bool]
        ), Value>
    ) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let values = (
            attached: attachedStorage,
            attachedTerminals: attachedTerminalStorage,
            detached: detachedStorage,
            destroyed: destroyedStorage,
            updateRegistrations: updateRegistrationStorage
        )
        return values[keyPath: keyPath]
    }
}

@Suite
struct TerminalBytesLogicTests {
    @MainActor
    private func waitUntilObserved(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        while true {
            var satisfied = false
            let changes = AsyncStream.makeStream(
                of: Void.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            withObservationTracking({
                satisfied = predicate()
            }, onChange: {
                changes.continuation.yield()
                changes.continuation.finish()
            })
            if satisfied {
                changes.continuation.finish()
                return
            }
            for await _ in changes.stream { break }
        }
    }

    @Test
    func demoConfigurationUsesOnlyExplicitEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invitation = directory.appendingPathComponent("invitation.txt")
        try "cmux://enroll/fresh\n".write(to: invitation, atomically: true, encoding: .utf8)

        let configuration = DemoLaunchConfiguration.processEnvironment([
            "CMUX_TERMINAL_INVITATION_FILE": invitation.path,
            "CMUX_TERMINAL_ID": "term_0123456789abcdef0123456789abcdef",
            "CMUX_TERMINAL_AUTOCONNECT": "1",
        ])

        #expect(
            configuration
                == DemoLaunchConfiguration(
                    invitation: "cmux://enroll/fresh",
                    terminalID: "term_0123456789abcdef0123456789abcdef",
                    autoConnect: true
                ))
    }

    @Test
    func stableTerminalIDValidationRejectsLegacySurfaceHandles() {
        #expect(isTerminalPublicID("term_0123456789abcdef0123456789abcdef"))
        #expect(!isTerminalPublicID("73"))
        #expect(!isTerminalPublicID("term_0123456789ABCDEF0123456789ABCDEF"))
        #expect(!isTerminalPublicID("pane_0123456789abcdef0123456789abcdef"))
    }

    @Test
    func geometrySubtractsTextInsetsAndClampsToValidCells() {
        #expect(
            terminalGeometry(
                width: 0,
                height: 0,
                horizontalInset: 16,
                verticalInset: 16
            ) == TerminalGeometry(cols: 1, rows: 1)
        )
        #expect(
            terminalGeometry(
                width: 840,
                height: 340,
                horizontalInset: 16,
                verticalInset: 16
            ) == TerminalGeometry(cols: 98, rows: 19)
        )
    }

    @Test
    func selectionClampsToAValidInsertionPointWhenTheFrameShrinks() {
        let surviving = NSValue(range: NSRange(location: 2, length: 1))
        let clipped = NSValue(range: NSRange(location: 2, length: 4))
        let removed = NSValue(range: NSRange(location: 12, length: 4))

        let selections = terminalSelections(
            preserving: [surviving, removed],
            utf16Length: 4
        )

        #expect(selections.map(\.rangeValue) == [NSRange(location: 2, length: 1)])
        #expect(
            terminalSelections(preserving: [clipped], utf16Length: 4).map(\.rangeValue)
                == [NSRange(location: 2, length: 2)]
        )
        #expect(
            terminalSelections(preserving: [removed], utf16Length: 4).map(\.rangeValue)
                == [NSRange(location: 4, length: 0)]
        )
        #expect(
            terminalSelections(preserving: [], utf16Length: 0).map(\.rangeValue)
                == [NSRange(location: 0, length: 0)]
        )

        #expect(
            terminalSelections(
                preserving: [NSValue(range: NSRange(location: 3, length: 2))],
                applying: TerminalTextEdit(
                    range: NSRange(location: 1, length: 0),
                    replacement: "XX"
                ),
                utf16Length: 7
            ).map(\.rangeValue) == [NSRange(location: 5, length: 2)]
        )
        #expect(
            terminalSelections(
                preserving: [NSValue(range: NSRange(location: 5, length: 2))],
                applying: TerminalTextEdit(
                    range: NSRange(location: 1, length: 2),
                    replacement: ""
                ),
                utf16Length: 5
            ).map(\.rangeValue) == [NSRange(location: 3, length: 2)]
        )
        #expect(
            terminalSelections(
                preserving: [NSValue(range: NSRange(location: 2, length: 4))],
                applying: TerminalTextEdit(
                    range: NSRange(location: 3, length: 3),
                    replacement: "Q"
                ),
                utf16Length: 6
            ).map(\.rangeValue) == [NSRange(location: 2, length: 2)]
        )
    }

    @Test
    func terminalTextUpdatesReplaceOnlyTheChangedUTF16Range() throws {
        let changed = try #require(terminalTextEdit(from: "a😀oldz", to: "a😀newz"))
        #expect(changed.range == NSRange(location: 3, length: 3))
        #expect(changed.replacement == "new")

        let appended = try #require(terminalTextEdit(from: "abc", to: "abcdef"))
        #expect(appended.range == NSRange(location: 3, length: 0))
        #expect(appended.replacement == "def")

        #expect(terminalTextEdit(from: "same", to: "same") == nil)
    }

    @Test
    func cStringCopyRetriesWhenValueGrowsBetweenPasses() {
        var calls = 0
        let value = copyGrowingCString { buffer, capacity in
            calls += 1
            let bytes = Array((calls == 1 ? "old" : "new-日本語").utf8)
            if let buffer, capacity > 0 {
                let copied = min(bytes.count, capacity - 1)
                for index in 0..<copied {
                    buffer[index] = CChar(bitPattern: bytes[index])
                }
                buffer[copied] = 0
            }
            return bytes.count
        }
        #expect(value == "new-日本語")
        #expect(calls >= 3)
    }

    @Test
    func namedKeysAndModifiersBecomeGhosttyChords() {
        #expect(terminalKeyChord(keyCode: 126, modifiers: []) == "up")
        #expect(
            terminalKeyChord(
                keyCode: 123,
                modifiers: [.control, .option]
            ) == "ctrl+alt+left"
        )
        #expect(terminalKeyChord(keyCode: 48, modifiers: [.shift]) == "shift+tab")
        #expect(terminalKeyChord(keyCode: 111, modifiers: []) == "f12")
        #expect(
            terminalKeyChord(
                keyCode: 8,
                modifiers: [.control],
                charactersIgnoringModifiers: "c"
            ) == "ctrl+c"
        )
        #expect(
            terminalKeyChord(
                keyCode: 2,
                modifiers: [.control],
                charactersIgnoringModifiers: "d"
            ) == "ctrl+d"
        )
    }

    @Test
    func rejectedResizeRemainsPendingAndReconnectResendsTheLatestGeometry() {
        let first = TerminalGeometry(cols: 100, rows: 30)
        let second = TerminalGeometry(cols: 120, rows: 40)
        var delivery = GeometryDeliveryState()

        delivery.update(first)
        #expect(delivery.pending(isConnected: false) == nil)
        #expect(delivery.pending(isConnected: true) == first)
        delivery.complete(first, accepted: false)
        #expect(delivery.pending(isConnected: true) == first)
        delivery.complete(first, accepted: true)
        #expect(delivery.pending(isConnected: true) == nil)

        delivery.update(second)
        delivery.complete(second, accepted: true)
        #expect(delivery.pending(isConnected: true) == nil)
        delivery.resetConnection()
        #expect(delivery.pending(isConnected: true) == second)
    }

    @Test @MainActor
    func rejectedResizeDoesNotImmediatelyRetryForever() async throws {
        let attempts = LockedCounter()
        let handle = TerminalClientHandle(
            rawAddress: 5,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            resizeClient: { _, _, _ in
                attempts.increment()
                return false
            },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: true
        )

        model.resize(to: TerminalGeometry(cols: 120, rows: 40))
        await attempts.wait { $0 > 0 }
        for _ in 0..<100 {
            model.resize(to: TerminalGeometry(cols: 120, rows: 40))
        }
        await attempts.wait { $0 >= 4 }
        await Task.yield()
        #expect(attempts.value == 4)
        model.shutdown()
    }

    @Test @MainActor
    func rejectedResizeRetryUsesTheInjectedClockAndCancelsOnShutdown() async throws {
        let attempts = LockedCounter()
        let clock = ManualTerminalClock()
        let handle = TerminalClientHandle(
            rawAddress: 11,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            resizeClient: { _, _, _ in
                attempts.increment()
                return false
            },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: true,
            clock: clock.clock
        )

        model.resize(to: TerminalGeometry(cols: 120, rows: 40))
        await attempts.wait { $0 == 1 }
        #expect(await clock.nextSleepDeadline() == .milliseconds(50))

        clock.advance(by: .milliseconds(50))
        await attempts.wait { $0 == 2 }
        #expect(await clock.nextSleepDeadline() == .milliseconds(150))

        model.shutdown()
        clock.advance(by: .seconds(1))
        await Task.yield()
        #expect(attempts.value == 2)
    }

    @Test @MainActor
    func clientHandleRetainsEnrollmentAndPropagatesInputFailure() async throws {
        let rawAddress: UInt = 1
        let calls = LockedClientCalls()
        let handle = TerminalClientHandle(
            rawAddress: rawAddress,
            attachClient: { client, terminal, _, _, _ in
                calls.recordAttach(client: client, terminal: String(cString: terminal!))
                return true
            },
            destroyClient: { calls.recordDestroy($0) },
            detachClient: { calls.recordDetach($0) },
            setUpdateCallback: { _, callback, _ in
                calls.recordUpdateRegistration(callback != nil)
            },
            sendClient: { _, _, _ in false },
            pasteClient: { _, _, _ in true },
            keyClient: { _, _, _ in true },
            resizeClient: { _, _, _ in true }
        )

        #expect(await handle.submit(.bytes(Data("x".utf8))) == false)
        #expect(await handle.submit(.paste("貼り付け")) == true)
        #expect(await handle.submit(.key(chord: "up", repeat: false)) == true)

        let firstUpdates = await handle.updates()
        let secondUpdates = await handle.updates()
        await handle.stopUpdates(generation: firstUpdates.generation)
        #expect(calls.updateRegistrations == [true, false, true])
        await handle.stopUpdates(generation: secondUpdates.generation)
        #expect(calls.updateRegistrations == [true, false, true, false])

        await handle.disconnect()
        await handle.disconnect()
        #expect(calls.detached == [rawAddress])
        #expect(
            await handle.reconnect(terminalID: "term_0123456789abcdef0123456789abcdef")
                == nil
        )
        #expect(
            await handle.reconnect(terminalID: "term_0123456789abcdef0123456789abcdef")
                == nil
        )
        #expect(calls.attached == [rawAddress])
        #expect(calls.attachedTerminals == ["term_0123456789abcdef0123456789abcdef"])

        await handle.shutdown()
        await handle.shutdown()
        #expect(calls.destroyed == [rawAddress])
    }

    @Test @MainActor
    func terminalInputIsBoundedAndDeliveredInFIFOOrder() async throws {
        let inputs = LockedInputs()
        let firstStarted = LockedFlag()
        let releaseFirst = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            rawAddress: 7,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            sendClient: { _, buffer, length in
                let bytes = buffer.map {
                    Array(UnsafeBufferPointer(start: $0, count: length))
                } ?? []
                let position = inputs.record(String(decoding: bytes, as: UTF8.self))
                if position == 1 {
                    firstStarted.set()
                    releaseFirst.wait()
                }
                return true
            },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: true
        )

        model.submit(.bytes(Data("0".utf8)))
        await firstStarted.waitUntilSet()
        for value in 1...300 {
            model.submit(.bytes(Data(String(value).utf8)))
        }
        #expect(!model.errorMessage.isEmpty)

        releaseFirst.signal()
        await inputs.wait { $0.count == 257 }
        #expect(inputs.values == (0...256).map(String.init))
        model.shutdown()
    }

    @Test @MainActor
    func terminalInputRejectsAnOversizedPayloadBeforeTheEntryLimit() async throws {
        let harness = makeBlockingInputHarness()
        harness.model.submit(.bytes(Data("blocked".utf8)))
        await harness.firstStarted.waitUntilSet()

        harness.model.submit(.bytes(Data(repeating: 0x61, count: 1_048_577)))
        #expect(!harness.model.errorMessage.isEmpty)

        harness.releaseFirst.signal()
        harness.model.shutdown()
    }

    @Test @MainActor
    func terminalInputRejectsAggregateBytesBeforeTheEntryLimit() async throws {
        let harness = makeBlockingInputHarness()
        harness.model.submit(.bytes(Data("blocked".utf8)))
        await harness.firstStarted.waitUntilSet()

        let chunk = Data(repeating: 0x61, count: 1_048_576)
        for _ in 0..<5 {
            harness.model.submit(.bytes(chunk))
        }
        #expect(!harness.model.errorMessage.isEmpty)

        harness.releaseFirst.signal()
        harness.model.shutdown()
    }

    @Test @MainActor
    func reconnectDoesNotBlockTheMainActor() async throws {
        let attachStarted = LockedFlag()
        let releaseAttach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            rawAddress: 2,
            attachClient: { _, _, _, _, _ in
                attachStarted.set()
                releaseAttach.wait()
                return true
            },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        await handle.disconnect()
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle
        )

        model.connect()
        #expect(model.isConnecting)
        await attachStarted.waitUntilSet()
        #expect(model.isConnecting)

        releaseAttach.signal()
        await waitUntilObserved { model.isConnected && !model.isConnecting }
        model.shutdown()
    }

    @Test @MainActor
    func timedOutEnrollmentReturnsToARetryableState() async throws {
        let attempts = LockedCounter()
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "cmux://enroll/test",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            connectClient: { _, _ in
                attempts.increment()
                return ConnectedHandle(rawAddress: nil, error: "terminal connection timed out")
            }
        )

        model.connect()
        await attempts.wait { $0 == 1 }
        await waitUntilObserved { !model.isConnecting }
        #expect(!model.errorMessage.isEmpty)

        model.connect()
        await attempts.wait { $0 == 2 }
        await waitUntilObserved { !model.isConnecting }
        #expect(!model.errorMessage.isEmpty)
        model.shutdown()
    }

    @Test @MainActor
    func timedOutReconnectUsesADeadlineAndReturnsToARetryableState() async throws {
        let timeouts = LockedInputs()
        let handle = TerminalClientHandle(
            rawAddress: 9,
            attachClient: { _, _, error, capacity, timeoutMilliseconds in
                timeouts.record(String(timeoutMilliseconds))
                _ = copyTestCString(
                    "terminal connection timed out",
                    buffer: error,
                    capacity: capacity
                )
                return false
            },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        await handle.disconnect()
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle
        )

        model.connect()
        await timeouts.wait { $0 == ["15000"] }
        await waitUntilObserved { !model.isConnecting }
        #expect(!model.errorMessage.isEmpty)

        model.connect()
        await timeouts.wait { $0 == ["15000", "15000"] }
        await waitUntilObserved { !model.isConnecting }
        #expect(!model.errorMessage.isEmpty)
        model.shutdown()
    }

    @Test @MainActor
    func changedInvitationReplacesTheRetainedEnrollment() async throws {
        let attached = LockedFlag()
        let destroyed = LockedFlag()
        let invitations = LockedInputs()
        let handle = TerminalClientHandle(
            rawAddress: 10,
            attachClient: { _, _, _, _, _ in
                attached.set()
                return true
            },
            destroyClient: { _ in destroyed.set() },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        await handle.disconnect()
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "cmux://enroll/old",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            connectClient: { invitation, _ in
                invitations.record(invitation)
                return ConnectedHandle(rawAddress: nil, error: "replacement rejected")
            }
        )

        model.invitation = "cmux://enroll/new"
        model.connect()

        await invitations.wait { $0 == ["cmux://enroll/new"] }
        await destroyed.waitUntilSet()
        await waitUntilObserved { !model.isConnecting }
        #expect(!attached.value)
        model.shutdown()
    }

    @Test @MainActor
    func disconnectDoesNotBlockTheMainActor() async throws {
        let detachStarted = LockedFlag()
        let releaseDetach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            rawAddress: 3,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in
                detachStarted.set()
                releaseDetach.wait()
            },
            setUpdateCallback: { _, _, _ in },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: true
        )

        model.disconnect()
        #expect(!model.isConnected)
        #expect(model.isConnecting)
        await detachStarted.waitUntilSet()
        #expect(model.isConnecting)

        releaseDetach.signal()
        await waitUntilObserved { !model.isConnecting }
        model.shutdown()
    }

    @Test @MainActor
    func disconnectClearsThePreviousTerminalFrameBeforeReconnect() async throws {
        let liveDiagnostics = #"{"status":"live","ready":true}"#
        let handle = TerminalClientHandle(
            rawAddress: 6,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, callback, context in
                callback?(context)
            },
            copyFrameClient: { _, buffer, capacity in
                copyTestCString("terminal A", buffer: buffer, capacity: capacity)
            },
            copyDiagnosticsClient: { _, buffer, capacity in
                copyTestCString(liveDiagnostics, buffer: buffer, capacity: capacity)
            },
            hasExitedClient: { _ in false }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle
        )

        model.connect()
        await waitUntilObserved { model.frame == "terminal A" }
        model.disconnect()
        #expect(model.frame.isEmpty)
        model.shutdown()
    }

    @Test @MainActor
    func structuredExitStateClosesTheAttachmentWithoutParsingDiagnostics() async throws {
        let exitedDiagnostics = "not-json"
        let handle = TerminalClientHandle(
            rawAddress: 4,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, callback, context in
                callback?(context)
            },
            sendClient: { _, _, _ in false },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, buffer, capacity in
                let bytes = Array(exitedDiagnostics.utf8)
                if let buffer, capacity > 0 {
                    let copied = min(bytes.count, capacity - 1)
                    for index in 0..<copied {
                        buffer[index] = CChar(bitPattern: bytes[index])
                    }
                    buffer[copied] = 0
                }
                return bytes.count
            },
            hasExitedClient: { _ in true }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle
        )

        model.connect()
        await waitUntilObserved { model.diagnostics == exitedDiagnostics }
        #expect(!model.isConnected)
        model.submit(.bytes(Data("x".utf8)))
        #expect(model.errorMessage.isEmpty)
        model.shutdown()
    }
}

private func copyTestCString(
    _ value: String,
    buffer: UnsafeMutablePointer<CChar>?,
    capacity: Int
) -> Int {
    let bytes = Array(value.utf8)
    if let buffer, capacity > 0 {
        let copied = min(bytes.count, capacity - 1)
        for index in 0..<copied {
            buffer[index] = CChar(bitPattern: bytes[index])
        }
        buffer[copied] = 0
    }
    return bytes.count
}
