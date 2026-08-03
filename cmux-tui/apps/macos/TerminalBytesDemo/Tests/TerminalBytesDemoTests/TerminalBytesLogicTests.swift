import AppKit
import Foundation
import Testing

@testable import TerminalBytesDemo

private final class LockedFlag: @unchecked Sendable {
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
    func clientHandleRetainsEnrollmentAndPropagatesInputFailure() throws {
        let raw = try #require(OpaquePointer(bitPattern: 1))
        var attached: [OpaquePointer] = []
        var attachedTerminals: [String] = []
        var detached: [OpaquePointer] = []
        var destroyed: [OpaquePointer] = []
        let handle = TerminalClientHandle(
            raw: raw,
            attachClient: { client, terminal, _, _ in
                attached.append(client)
                attachedTerminals.append(String(cString: terminal!))
                return true
            },
            destroyClient: { destroyed.append($0) },
            detachClient: { detached.append($0) },
            sendClient: { _, _, _ in false },
            pasteClient: { _, _, _ in true },
            keyClient: { _, _, _ in true },
            resizeClient: { _, _, _ in true }
        )

        #expect(handle.submit(.bytes(Data("x".utf8))) == false)
        #expect(handle.submit(.paste("貼り付け")) == true)
        #expect(handle.submit(.key(chord: "up", repeat: false)) == true)

        handle.disconnect()
        handle.disconnect()
        #expect(detached == [raw])
        #expect(
            handle.reconnect(terminalID: "term_0123456789abcdef0123456789abcdef") == nil
        )
        #expect(
            handle.reconnect(terminalID: "term_0123456789abcdef0123456789abcdef") == nil
        )
        #expect(attached == [raw])
        #expect(attachedTerminals == ["term_0123456789abcdef0123456789abcdef"])

        handle.shutdown()
        handle.shutdown()
        #expect(destroyed == [raw])
    }

    @Test @MainActor
    func reconnectDoesNotBlockTheMainActor() async throws {
        let raw = try #require(OpaquePointer(bitPattern: 2))
        let attachStarted = LockedFlag()
        let releaseAttach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            raw: raw,
            attachClient: { _, _, _, _ in
                attachStarted.set()
                releaseAttach.wait()
                return true
            },
            destroyClient: { _ in },
            detachClient: { _ in },
            copyFrameClient: { _, _, _ in 0 },
            copyDiagnosticsClient: { _, _, _ in 0 }
        )
        handle.disconnect()
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
        let raw = try #require(OpaquePointer(bitPattern: 3))
        let detachStarted = LockedFlag()
        let releaseDetach = DispatchSemaphore(value: 0)
        let handle = TerminalClientHandle(
            raw: raw,
            attachClient: { _, _, _, _ in true },
            destroyClient: { _ in },
            detachClient: { _ in
                detachStarted.set()
                releaseDetach.wait()
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

        model.disconnect()
        #expect(!model.isConnected)
        #expect(model.isConnecting)
        #expect(await waitUntil { detachStarted.value })
        #expect(model.isConnecting)

        releaseDetach.signal()
        #expect(await waitUntil { !model.isConnecting })
        model.shutdown()
    }
}
