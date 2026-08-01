import AppKit
import Foundation
import Testing
@testable import TerminalBytesDemo

@Suite
struct TerminalBytesLogicTests {
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
            "CMUX_TERMINAL_SURFACE": "73",
            "CMUX_TERMINAL_AUTOCONNECT": "1",
        ])

        #expect(configuration == DemoLaunchConfiguration(
            invitation: "cmux://enroll/fresh",
            surface: "73",
            autoConnect: true
        ))
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
        var attachedSurfaces: [UInt64] = []
        var detached: [OpaquePointer] = []
        var destroyed: [OpaquePointer] = []
        let handle = TerminalClientHandle(
            raw: raw,
            attachClient: { client, surface, _, _ in
                attached.append(client)
                attachedSurfaces.append(surface)
                return true
            },
            destroyClient: { destroyed.append($0) },
            detachClient: { detached.append($0) },
            sendClient: { _, _, _ in false },
            pasteClient: { _, _, _ in true },
            keyClient: { _, _, _ in true },
            resizeClient: { _, _, _ in true }
        )

        #expect(handle.withRaw { $0 } == raw)
        #expect(handle.submit(.bytes(Data("x".utf8))) == false)
        #expect(handle.submit(.paste("貼り付け")) == true)
        #expect(handle.submit(.key(chord: "up", repeat: false)) == true)

        handle.disconnect()
        handle.disconnect()
        #expect(handle.withRaw { $0 } == raw)
        #expect(detached == [raw])
        #expect(handle.reconnect(surface: 73) == nil)
        #expect(handle.reconnect(surface: 73) == nil)
        #expect(attached == [raw])
        #expect(attachedSurfaces == [73])

        handle.shutdown()
        handle.shutdown()
        #expect(handle.withRaw { $0 } == nil)
        #expect(destroyed == [raw])
    }
}
