import CMUXMobileCore
import CmuxMobileRPC
import Foundation
@testable import CmuxMobileShell

// Wire-format event-frame fixture builders shared by the render-grid
// liveness, replay-staleness, and cold-attach-barrier tests. Split from
// MobileShellRenderGridLivenessTestSupport.swift to respect that file's
// length budget.

func renderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    columns: Int = 16,
    rows: Int = 4,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true
) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: columns,
        rows: rows,
        full: full,
        rowSpans: [
            MobileTerminalRenderGridFrame.RowSpan(
                row: 0,
                column: 0,
                styleID: 0,
                text: text
            ),
        ],
        activeScreen: activeScreen
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

func terminalBytesEventFrame(surfaceID: String, seq: UInt64, text: String) throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.bytes",
        "payload": [
            "surface_id": surfaceID,
            "seq": seq,
            "data_b64": Data(text.utf8).base64EncodedString(),
        ],
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

func emptyRenderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    activeScreen: MobileTerminalRenderGridFrame.Screen,
    full: Bool = false
) throws -> Data {
    let frame = try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        full: full,
        rowSpans: [],
        activeScreen: activeScreen
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}
