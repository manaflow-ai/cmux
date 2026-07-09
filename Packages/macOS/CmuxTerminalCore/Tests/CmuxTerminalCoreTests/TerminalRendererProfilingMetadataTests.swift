import Foundation
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
