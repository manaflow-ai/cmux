import CMUXMobileCore
import CmuxMobileRPC
import Foundation

func renderGridFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
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
}

func renderGridEventFrame(
    surfaceID: String,
    seq: UInt64,
    text: String,
    activeScreen: MobileTerminalRenderGridFrame.Screen = .primary,
    full: Bool = true
) throws -> Data {
    let frame = try renderGridFrame(
        surfaceID: surfaceID,
        seq: seq,
        text: text,
        activeScreen: activeScreen,
        full: full
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

/// Poll until `condition` is true, bounded at `attempts` x 10ms. Returns the
/// final value so tests can assert both presence and (bounded) absence.
@MainActor
func pollUntil(
    attempts: Int = 300,
    _ condition: @MainActor () async -> Bool
) async throws -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}
