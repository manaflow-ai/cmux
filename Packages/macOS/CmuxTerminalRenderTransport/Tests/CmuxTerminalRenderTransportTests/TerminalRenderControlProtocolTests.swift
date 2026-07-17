import Foundation
import Testing
@testable import CmuxTerminalRenderTransport

@Suite struct TerminalRenderControlProtocolTests {
    @Test func commandsRoundTripThroughBinaryCodec() throws {
        let endpoint = try TerminalRenderFrameEndpoint(
            serviceName: "dev.cmux.test.endpoint",
            authenticationToken: Data(repeating: 0xA5, count: 16)
        )
        let configuration = TerminalRenderConfigurationSnapshot(
            revision: 7,
            contents: "font-size = 14\n"
        )
        let id = UUID(uuidString: "184DCEB4-F88C-4A9D-89F4-03087E606B8B")!
        let descriptor = TerminalRenderSurfaceDescriptor(
            id: id,
            generation: 3,
            width: 1_600,
            height: 900,
            scaleX: 2,
            scaleY: 2,
            fontSize: 15,
            context: 2
        )
        let mutations: [TerminalRenderSurfaceMutation] = [
            .processOutput(sequence: 41, bytes: Data([0, 1, 2, 0xff])),
            .resize(width: 900, height: 700),
            .contentScale(x: 2, y: 2),
            .focus(true),
            .occlusion(false),
            .colorScheme(1),
            .rendererRealized(false),
            .refresh,
            .preedit(text: "かな", selectionStart: 0, selectionLength: 1),
            .mousePosition(x: 12.5, y: 9.25, modifiers: 3),
            .mouseButton(state: 1, button: 0, modifiers: 4),
            .mouseScroll(deltaX: 1.5, deltaY: -2.5, modifiers: 8),
            .clearSelection,
            .bindingAction("scroll_page_up"),
        ]
        let commands: [TerminalRenderWorkerCommand] = [
            .initialize(
                protocolVersion: TerminalRenderProtocol.currentVersion,
                workerGeneration: 12,
                frameEndpoint: endpoint,
                configuration: configuration
            ),
            .replaceConfiguration(configuration),
            .createSurface(descriptor),
            .resynchronizeSurface(
                descriptor: descriptor,
                nextOutputSequence: 99,
                screenTailVT: Data("\u{1b}[2Jrestored".utf8)
            ),
            .destroySurface(id: id, generation: 3),
            .shutdown,
        ] + mutations.map {
            .mutateSurface(id: id, generation: 3, mutation: $0)
        }

        for command in commands {
            let encoded = try TerminalRenderControlCodec.encode(command)
            #expect(try TerminalRenderControlCodec.decodeCommand(encoded) == command)
        }
    }

    @Test func eventsRoundTripThroughBinaryCodec() throws {
        let id = UUID()
        let events: [TerminalRenderWorkerEvent] = [
            .initialized(protocolVersion: 1, workerGeneration: 12, processIdentifier: 123),
            .surfaceCreated(id: id, generation: 9),
            .surfaceDestroyed(id: id, generation: 9),
            .outputApplied(id: id, generation: 9, nextSequence: 1_024),
            .resizeApplied(id: id, generation: 9, width: 1_600, height: 900),
            .failure("bad command"),
        ]

        for event in events {
            let encoded = try TerminalRenderControlCodec.encode(event)
            #expect(try TerminalRenderControlCodec.decodeEvent(encoded) == event)
        }
    }

    @Test func endpointRejectsWrongTokenSize() {
        #expect(throws: TerminalRenderProtocolError.invalidFrameEndpoint) {
            try TerminalRenderFrameEndpoint(
                serviceName: "dev.cmux.test.endpoint",
                authenticationToken: Data(repeating: 0, count: 15)
            )
        }
    }
}
