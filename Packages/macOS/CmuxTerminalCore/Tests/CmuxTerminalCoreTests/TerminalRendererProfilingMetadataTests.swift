import Foundation
import OSLog
import Testing
@testable import CmuxTerminalCore

@Suite struct TerminalRendererProfilingMetadataTests {
    @Test func updateDetailsContainOnlyTypedRendererState() {
        let identity = TerminalRendererProfilingIdentity(
            workspaceId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            surfaceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let metadata = TerminalRendererProfilingMetadata(
            identity: identity,
            visible: true,
            focused: false,
            wakeReason: .terminalOutput,
            coalescedUpdateCount: 7,
            dirtyRowCount: 3,
            fullRedraw: false
        )

        #expect(
            metadata.details ==
                "workspace=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE " +
                "surface=11111111-2222-3333-4444-555555555555 " +
                "visible=1 focused=0 wake=terminal-output coalesced=7 dirty_rows=3 full_redraw=0"
        )
    }

    @Test func metadataAPIHasNoUserContentInput() {
        let identity = TerminalRendererProfilingIdentity(
            workspaceId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            surfaceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let metadata = TerminalRendererProfilingMetadata(
            identity: identity,
            visible: false,
            focused: true,
            wakeReason: .displayLink,
            coalescedUpdateCount: 1,
            dirtyRowCount: 0,
            fullRedraw: true
        )

        for forbidden in ["secret command", "/Users/example/private", "API_TOKEN=value"] {
            #expect(!metadata.details.contains(forbidden))
        }
        #expect(Set(metadata.details.split(separator: " ").map { $0.split(separator: "=")[0] }) == [
            "workspace", "surface", "visible", "focused", "wake", "coalesced", "dirty_rows", "full_redraw",
        ])
    }
}

@Suite struct TerminalRendererProfilingSignpostsTests {
    @Test func disabledCollectionDoesNotEvaluateMetadata() {
        let signposts = TerminalRendererProfilingSignposts(
            signposter: OSSignposter(
                subsystem: "com.cmux.terminal-renderer-tests",
                category: .pointsOfInterest
            ),
            collectionRequested: false
        )
        var evaluationCount = 0

        func metadata() -> TerminalRendererProfilingMetadata {
            evaluationCount += 1
            return TerminalRendererProfilingMetadata(
                identity: TerminalRendererProfilingIdentity(
                    workspaceId: UUID(),
                    surfaceId: UUID()
                ),
                visible: true,
                focused: true,
                wakeReason: .terminalOutput,
                coalescedUpdateCount: 1,
                dirtyRowCount: nil,
                fullRedraw: nil
            )
        }

        #expect(!signposts.isEnabled)
        #expect(signposts.beginFrame(metadata()) == nil)
        #expect(signposts.beginUpdate(metadata()) == nil)
        signposts.endFrame(nil, metadata())
        signposts.endUpdate(nil, metadata())
        #expect(evaluationCount == 0)
    }

    @Test func disabledCollectionDoesNotEvaluateRendererEventMetadata() {
        let signposts = TerminalRendererProfilingSignposts(
            signposter: OSSignposter(
                subsystem: "com.cmux.terminal-renderer-tests",
                category: .pointsOfInterest
            ),
            collectionRequested: false
        )
        var evaluationCount = 0

        func metadata() -> TerminalRendererEventProfilingMetadata {
            evaluationCount += 1
            return TerminalRendererEventProfilingMetadata(
                identity: TerminalRendererProfilingIdentity(
                    workspaceId: UUID(),
                    surfaceId: UUID()
                ),
                visible: true,
                focused: false,
                event: .updateFrameBegin
            )
        }

        #expect(signposts.beginRendererEvent(metadata()) == nil)
        signposts.endRendererEvent(nil, metadata())
        #expect(evaluationCount == 0)
    }
}

@Suite struct TerminalRendererEventTests {
    @Test func mapsEveryGhosttyRendererEventToClosedTypedState() {
        #expect(TerminalRendererProfilingEvent(GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_BEGIN) == .updateFrameBegin)
        #expect(TerminalRendererProfilingEvent(GHOSTTY_RENDERER_EVENT_UPDATE_FRAME_END) == .updateFrameEnd)
        #expect(TerminalRendererProfilingEvent(GHOSTTY_RENDERER_EVENT_DRAW_FRAME_BEGIN) == .drawFrameBegin)
        #expect(TerminalRendererProfilingEvent(GHOSTTY_RENDERER_EVENT_DRAW_FRAME_END) == .drawFrameEnd)
    }

    @Test func pairsUpdateAndDrawIntervalsIndependently() {
        var pairing = TerminalRendererEventPairing()

        #expect(pairing.consume(.updateFrameBegin) == .begin(.updateFrame))
        #expect(pairing.consume(.drawFrameBegin) == .begin(.drawFrame))
        #expect(pairing.consume(.drawFrameEnd) == .end(.drawFrame))
        #expect(pairing.consume(.updateFrameEnd) == .end(.updateFrame))
        #expect(pairing.consume(.updateFrameEnd) == nil)
    }

    @Test func eventMetadataContainsOnlyOpaqueIdentityAndTypedState() {
        let metadata = TerminalRendererEventProfilingMetadata(
            identity: TerminalRendererProfilingIdentity(
                workspaceId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                surfaceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            visible: false,
            focused: true,
            event: .drawFrameEnd
        )

        #expect(
            metadata.details ==
                "workspace=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE " +
                "surface=11111111-2222-3333-4444-555555555555 " +
                "visible=0 focused=1 event=draw-frame-end"
        )
        #expect(Set(metadata.details.split(separator: " ").map { $0.split(separator: "=")[0] }) == [
            "workspace", "surface", "visible", "focused", "event",
        ])
    }
}
