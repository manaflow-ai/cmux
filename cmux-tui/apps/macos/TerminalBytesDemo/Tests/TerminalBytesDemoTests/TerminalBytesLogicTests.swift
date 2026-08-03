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
        let removed = NSValue(range: NSRange(location: 12, length: 4))

        let selections = terminalSelections(
            preserving: [surviving, removed],
            utf16Length: 4
        )

        #expect(selections.map(\.rangeValue) == [NSRange(location: 2, length: 1)])
        #expect(
            terminalSelections(preserving: [removed], utf16Length: 4).map(\.rangeValue)
                == [NSRange(location: 4, length: 0)]
        )
        #expect(
            terminalSelections(preserving: [], utf16Length: 0).map(\.rangeValue)
                == [NSRange(location: 0, length: 0)]
        )
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
    func clientHandleRetainsEnrollmentAndPropagatesInputFailure() async throws {
        let rawAddress: UInt = 1
        let calls = LockedClientCalls()
        let handle = TerminalClientHandle(
            rawAddress: rawAddress,
            attachClient: { client, terminal, _, _ in
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
    func reconnectDoesNotBlockTheMainActor() async throws {
        let attachStarted = LockedFlag()
        let releaseAttach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            rawAddress: 2,
            attachClient: { _, _, _, _ in
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
        #expect(await waitUntil { attachStarted.value })
        #expect(model.isConnecting)

        releaseAttach.signal()
        #expect(await waitUntil { model.isConnected && !model.isConnecting })
        model.shutdown()
    }

    @Test @MainActor
    func disconnectDoesNotBlockTheMainActor() async throws {
        let detachStarted = LockedFlag()
        let releaseDetach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            rawAddress: 3,
            attachClient: { _, _, _, _ in true },
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
        #expect(await waitUntil { detachStarted.value })
        #expect(model.isConnecting)

        releaseDetach.signal()
        #expect(await waitUntil { !model.isConnecting })
        model.shutdown()
    }

    @Test @MainActor
    func exitedDiagnosticsCloseTheAttachmentWithoutAnInputError() async throws {
        let exitedDiagnostics = #"{"status":"exited","ready":false}"#
        let handle = TerminalClientHandle(
            rawAddress: 4,
            attachClient: { _, _, _, _ in true },
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
            }
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
