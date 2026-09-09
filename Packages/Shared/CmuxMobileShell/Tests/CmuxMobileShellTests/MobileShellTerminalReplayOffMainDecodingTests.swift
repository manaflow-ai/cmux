import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

// Behavior tests for the off-main replay decode: the helper must produce
// exactly what the previous inline main-actor decode produced (JSON payload
// plus decoded base64 tails), so moving the work off the main actor cannot
// change what the replay path applies.

@Test func offMainReplayDecodeMatchesInlineDecode() async throws {
    let rawTail = Data("raw pty tail".utf8)
    let snapshot = Data("vt snapshot bytes".utf8)
    let payloadJSON: [String: Any] = [
        "data_b64": rawTail.base64EncodedString(),
        "snapshot_data_b64": snapshot.base64EncodedString(),
        "seq": 42,
        "columns": 80,
        "rows": 24,
    ]
    let data = try JSONSerialization.data(withJSONObject: payloadJSON)

    let decoded = await MobileShellComposite.decodeTerminalReplayResponseOffMain(data)

    let inline = try MobileTerminalReplayResponse.decode(data)
    let payload = try #require(decoded.payload)
    #expect(payload.dataBase64 == inline.dataBase64)
    #expect(payload.snapshotBase64 == inline.snapshotBase64)
    #expect(payload.sequence == 42)
    #expect(payload.columns == 80)
    #expect(payload.rows == 24)
    #expect(decoded.bytes == rawTail)
    #expect(decoded.snapshotBytes == snapshot)
}

@Test func offMainReplayDecodeToleratesAMalformedPayload() async {
    let decoded = await MobileShellComposite.decodeTerminalReplayResponseOffMain(
        Data("not json".utf8)
    )

    #expect(decoded.payload == nil)
    #expect(decoded.bytes == nil)
    #expect(decoded.snapshotBytes == nil)
}

@Test func offMainReplayDecodeOmitsAbsentTails() async throws {
    let data = try JSONSerialization.data(withJSONObject: ["seq": 7])

    let decoded = await MobileShellComposite.decodeTerminalReplayResponseOffMain(data)

    #expect(decoded.payload?.sequence == 7)
    #expect(decoded.bytes == nil)
    #expect(decoded.snapshotBytes == nil)
}
