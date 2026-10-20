import AppKit
import Foundation
import Testing

@testable import TerminalBytesDemo

private final class LockedFlag: @unchecked Sendable {
    // NSLock protects every access to storage, including calls from injected
    // C-operation closures that the compiler must treat as concurrent.
    private let lock = NSLock()
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
    }
}

private final class LockedCounter: @unchecked Sendable {
    // NSLock protects every access from injected concurrent client operations.
    private let lock = NSLock()
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
    }
}

private final class LockedInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func record(_ value: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
        return storage.count
    }
}

private final class LockedResizeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var nextRequestID: UInt64 = 1
    private var requestStorage: [TerminalResizeSubmission] = []
    private var acknowledgementStorage: TerminalResizeAcknowledgement?

    var requests: [TerminalResizeSubmission] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func submit(
        cols: UInt16,
        rows: UInt16,
        requestID: UnsafeMutablePointer<UInt64>?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestID
        nextRequestID += 1
        requestID?.pointee = id
        requestStorage.append(
            TerminalResizeSubmission(
                requestID: id,
                geometry: TerminalGeometry(cols: cols, rows: rows)
            )
        )
        return true
    }

    func acknowledge(_ submission: TerminalResizeSubmission) {
        lock.lock()
        acknowledgementStorage = TerminalResizeAcknowledgement(
            requestID: submission.requestID,
            geometry: submission.geometry,
            canonicalChanged: true
        )
        lock.unlock()
    }

    func copyAcknowledgement(
        requestID: UnsafeMutablePointer<UInt64>?,
        cols: UnsafeMutablePointer<UInt16>?,
        rows: UnsafeMutablePointer<UInt16>?,
        canonicalChanged: UnsafeMutablePointer<Bool>?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let acknowledgement = acknowledgementStorage else { return false }
        requestID?.pointee = acknowledgement.requestID
        cols?.pointee = acknowledgement.geometry.cols
        rows?.pointee = acknowledgement.geometry.rows
        canonicalChanged?.pointee = acknowledgement.canonicalChanged
        return true
    }
}

private final class LockedUpdateRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: TerminalUpdateCallback?
    private var context: UnsafeMutableRawPointer?

    func set(_ callback: TerminalUpdateCallback?, context: UnsafeMutableRawPointer?) {
        lock.lock()
        self.callback = callback
        self.context = context
        lock.unlock()
    }

    func notify() {
        lock.lock()
        let callback = callback
        let context = context
        lock.unlock()
        callback?(context)
    }
}

private final class TestTerminalClock: TerminalClock, @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let wake = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        stream = wake.stream
        continuation = wake.continuation
    }

    func sleep(for duration: Duration) async throws {
        for await _ in stream {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }

    func advance() {
        continuation.yield()
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
        resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        _ keyPath: KeyPath<
            (
                attached: [UInt],
                attachedTerminals: [String],
                detached: [UInt],
                destroyed: [UInt],
                updateRegistrations: [Bool]
            ), Value
        >
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
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
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
    func outputInsertedExactlyAtSelectionEndDoesNotExtendSelection() {
        let selections = terminalSelections(
            preserving: [NSValue(range: NSRange(location: 2, length: 3))],
            applying: TerminalTextEdit(
                range: NSRange(location: 5, length: 0),
                replacement: "new output"
            ),
            utf16Length: 15
        )

        #expect(selections.map(\.rangeValue) == [NSRange(location: 2, length: 3)])
    }

    @Test
    func selectionRemovedInsideReplacementCollapsesToEditStart() {
        let selections = terminalSelections(
            preserving: [NSValue(range: NSRange(location: 4, length: 2))],
            applying: TerminalTextEdit(
                range: NSRange(location: 3, length: 5),
                replacement: "replacement"
            ),
            utf16Length: 17
        )

        #expect(selections.map(\.rangeValue) == [NSRange(location: 3, length: 0)])
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
    func cStringCopyStopsAfterBoundedGrowth() {
        var calls = 0
        let value = copyGrowingCString { buffer, capacity in
            calls += 1
            let bytes = Array(repeating: UInt8(ascii: "x"), count: 32)
            if let buffer, capacity > 0 {
                buffer[0] = CChar(bitPattern: bytes[0])
                buffer[1] = 0
            }
            return bytes.count + calls
        }

        #expect(value == nil)
        #expect(calls == terminalCStringMaximumAttempts + 1)
    }

    @Test
    func cStringCopyRejectsNegativeCopyLength() {
        var calls = 0
        let value = copyGrowingCString { _, _ in
            calls += 1
            return calls == 1 ? 4 : -1
        }

        #expect(value == nil)
        #expect(calls == 2)
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
    func resizeDeliveryWaitsForMatchingAcknowledgementAndReconnectsLatestGeometry() {
        let first = TerminalGeometry(cols: 100, rows: 30)
        let second = TerminalGeometry(cols: 120, rows: 40)
        let firstSubmission = TerminalResizeSubmission(requestID: 7, geometry: first)
        let secondSubmission = TerminalResizeSubmission(requestID: 8, geometry: second)
        var delivery = GeometryDeliveryState()

        delivery.update(first)
        #expect(delivery.pending(isConnected: false) == nil)
        #expect(delivery.pending(isConnected: true) == first)
        delivery.submit(nil)
        #expect(delivery.pending(isConnected: true) == first)
        delivery.submit(firstSubmission)
        #expect(delivery.pending(isConnected: true) == nil)

        delivery.update(second)
        #expect(delivery.pending(isConnected: true) == nil)
        delivery.acknowledge(
            TerminalResizeAcknowledgement(
                requestID: firstSubmission.requestID,
                geometry: first,
                canonicalChanged: true
            )
        )
        #expect(delivery.pending(isConnected: true) == second)
        delivery.submit(secondSubmission)
        delivery.acknowledge(
            TerminalResizeAcknowledgement(
                requestID: secondSubmission.requestID,
                geometry: second,
                canonicalChanged: false
            )
        )
        #expect(delivery.pending(isConnected: true) == nil)
        delivery.resetConnection()
        #expect(delivery.pending(isConnected: true) == second)
    }

    @Test @MainActor
    func resizeAcknowledgementReleasesTheLatestPendingGeometry() async throws {
        let transport = LockedResizeTransport()
        let updates = LockedUpdateRegistration()
        let handle = TerminalClientHandle(
            rawAddress: 5,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, callback, context in
                updates.set(callback, context: context)
            },
            resizeClient: { _, cols, rows, requestID in
                transport.submit(cols: cols, rows: rows, requestID: requestID)
            },
            resizeAcknowledgementClient: { _, requestID, cols, rows, changed in
                transport.copyAcknowledgement(
                    requestID: requestID,
                    cols: cols,
                    rows: rows,
                    canonicalChanged: changed
                )
            },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 },
            hasExitedClient: { _ in false }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: false
        )

        model.connect()
        #expect(await waitUntil { model.isConnected })
        let first = TerminalGeometry(cols: 100, rows: 30)
        let second = TerminalGeometry(cols: 120, rows: 40)
        model.resize(to: first)
        #expect(await waitUntil { transport.requests.count == 1 })
        model.resize(to: second)
        await Task.yield()
        #expect(transport.requests.map(\.geometry) == [first])

        transport.acknowledge(transport.requests[0])
        updates.notify()
        #expect(await waitUntil { transport.requests.count == 2 })
        #expect(transport.requests.map(\.geometry) == [first, second])
        model.shutdown()
    }

    @Test @MainActor
    func lostResizeAcknowledgementRequeuesLatestGeometryAfterDeadline() async throws {
        let transport = LockedResizeTransport()
        let clock = TestTerminalClock()
        let handle = TerminalClientHandle(
            rawAddress: 6,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            resizeClient: { _, cols, rows, requestID in
                transport.submit(cols: cols, rows: rows, requestID: requestID)
            },
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 },
            hasExitedClient: { _ in false }
        )
        let model = TerminalModel(
            configuration: DemoLaunchConfiguration(
                invitation: "",
                terminalID: "term_0123456789abcdef0123456789abcdef",
                autoConnect: false
            ),
            retainedClient: handle,
            initiallyConnected: true,
            resizeClock: clock,
            resizeAcknowledgementTimeout: .seconds(1)
        )
        let first = TerminalGeometry(cols: 100, rows: 30)
        let latest = TerminalGeometry(cols: 120, rows: 40)

        model.resize(to: first)
        #expect(await waitUntil { transport.requests.count == 1 })
        model.resize(to: latest)
        clock.advance()

        #expect(await waitUntil { transport.requests.count == 2 })
        #expect(transport.requests.map(\.geometry) == [first, latest])
        #expect(model.errorMessage.contains("resize is pending"))

        clock.advance()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(transport.requests.count == 2)
        model.shutdown()
    }

    @Test @MainActor
    func rejectedResizeDoesNotRetryUntilGeometryChanges() async throws {
        let attempts = LockedCounter()
        let handle = TerminalClientHandle(
            rawAddress: 8,
            attachClient: { _, _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in },
            setUpdateCallback: { _, _, _ in },
            resizeClient: { _, _, _, _ in
                attempts.increment()
                return false
            },
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 },
            hasExitedClient: { _ in false }
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
        let geometry = TerminalGeometry(cols: 100, rows: 30)

        model.resize(to: geometry)
        #expect(await waitUntil { attempts.value == 1 })
        for _ in 0 ..< 10 {
            model.resize(to: geometry)
            await Task.yield()
        }
        #expect(attempts.value == 1)
        #expect(model.errorMessage.contains("resize is pending"))
        model.shutdown()
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
            resizeClient: { _, _, _, requestID in
                requestID?.pointee = 1
                return true
            }
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
                let bytes =
                    buffer.map {
                        Array(UnsafeBufferPointer(start: $0, count: length))
                    } ?? []
                let position = inputs.record(String(decoding: bytes, as: UTF8.self))
                if position == 1 {
                    firstStarted.set()
                    releaseFirst.wait()
                }
                return true
            },
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { firstStarted.value })
        for value in 1...300 {
            model.submit(.bytes(Data(String(value).utf8)))
        }
        #expect(!model.errorMessage.isEmpty)

        releaseFirst.signal()
        #expect(await waitUntil { inputs.values.count == 257 })
        #expect(inputs.values == (0...256).map(String.init))
        model.shutdown()
    }

    @Test @MainActor
    func terminalInputRejectsAnOversizedPayloadBeforeTheEntryLimit() async throws {
        let harness = makeBlockingInputHarness()
        harness.model.submit(.bytes(Data("blocked".utf8)))
        #expect(await waitUntil { harness.firstStarted.value })

        harness.model.submit(.bytes(Data(repeating: 0x61, count: 1_048_577)))
        #expect(!harness.model.errorMessage.isEmpty)

        harness.releaseFirst.signal()
        harness.model.shutdown()
    }

    @Test @MainActor
    func terminalInputRejectsAggregateBytesBeforeTheEntryLimit() async throws {
        let harness = makeBlockingInputHarness()
        harness.model.submit(.bytes(Data("blocked".utf8)))
        #expect(await waitUntil { harness.firstStarted.value })

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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { attachStarted.value })
        #expect(model.isConnecting)

        let actorProbeCompleted = LockedFlag()
        Task {
            _ = await handle.submit(.bytes(Data("probe".utf8)))
            actorProbeCompleted.set()
        }
        #expect(
            await waitUntil { actorProbeCompleted.value },
            "blocking attach occupied the terminal client actor executor"
        )

        releaseAttach.signal()
        #expect(await waitUntil { model.isConnected && !model.isConnecting })
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
        #expect(await waitUntil { attempts.value == 1 && !model.isConnecting })
        #expect(!model.errorMessage.isEmpty)

        model.connect()
        #expect(await waitUntil { attempts.value == 2 && !model.isConnecting })
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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { timeouts.values == ["15000"] && !model.isConnecting })
        #expect(!model.errorMessage.isEmpty)

        model.connect()
        #expect(
            await waitUntil {
                timeouts.values == ["15000", "15000"] && !model.isConnecting
            }
        )
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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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

        #expect(
            await waitUntil {
                invitations.values == ["cmux://enroll/new"] && destroyed.value
                    && !model.isConnecting
            }
        )
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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { detachStarted.value })
        #expect(model.isConnecting)

        releaseDetach.signal()
        #expect(await waitUntil { !model.isConnecting })
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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { model.frame == "terminal A" })
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
            resizeAcknowledgementClient: { _, _, _, _, _ in false },
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
        #expect(await waitUntil { model.diagnostics == exitedDiagnostics })
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
