import CmuxWorkspaceShare
import Foundation
import Testing

@Suite
struct ShareBinaryFrameBoundaryTests {
    @Test
    func `Complete-frame ceiling is exclusive`() throws {
        let headerByteCount = 5 // kind + lengths + one-byte ws + one-byte pane
        let acceptedPayload = Data(
            repeating: 0x61,
            count: ShareProtocolConstants.binaryFrameByteLimit
                - headerByteCount
                - 1
        )
        let accepted = try #require(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: "w",
                pane: "p",
                payload: acceptedPayload
            )
        )
        #expect(
            accepted.count == ShareProtocolConstants.binaryFrameByteLimit - 1
        )
        #expect(ShareBinaryFrame.decode(accepted)?.payload == acceptedPayload)

        let exactPayload = Data(
            repeating: 0x61,
            count: ShareProtocolConstants.binaryFrameByteLimit - headerByteCount
        )
        #expect(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: "w",
                pane: "p",
                payload: exactPayload
            ) == nil
        )
        #expect(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: "w",
                pane: "p",
                payload: exactPayload + Data([0x61])
            ) == nil
        )
    }

    @Test
    func `Decoder rejects malformed lengths UTF-8 controls and unknown kind`() {
        let malformed: [Data] = [
            Data(),
            Data([0x01, 0x01]),
            Data([0x01, 0x02, 0x61]),
            Data([0x01, 0x01, 0x77, 0x02, 0x70]),
            Data([0x01, 0x01, 0xFF, 0x01, 0x70]),
            Data([0x01, 0x01, 0x77, 0x01, 0xFF]),
            Data([0x02, 0x01, 0x77, 0x01, 0x70]),
            Data([0x01, 0x00, 0x01, 0x70]),
            Data([0x01, 0x01, 0x00, 0x01, 0x70]),
        ]

        for data in malformed {
            #expect(ShareBinaryFrame.decode(data) == nil)
        }
        #expect(
            ShareBinaryFrame.decode(
                Data(
                    repeating: 0,
                    count: ShareProtocolConstants.binaryFrameByteLimit
                )
            ) == nil
        )
    }

    @Test
    func `Deterministic fuzz never accepts a non-round-trippable frame`() {
        var state: UInt64 = 0xC0FFEE
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let count = Int((state >> 32) % 512)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            let data = Data(bytes)
            guard let decoded = ShareBinaryFrame.decode(data) else { continue }
            #expect(
                ShareBinaryFrame.encode(
                    kind: decoded.kind,
                    ws: decoded.ws,
                    pane: decoded.pane,
                    payload: decoded.payload
                ) == data
            )
        }
    }

    @Test
    func `Near-limit render-grid JSON remains one complete frame`() throws {
        let workspace = "workspace"
        let pane = "pane"
        let fixedHeaderBytes = 3 + workspace.utf8.count + pane.utf8.count
        let targetPayloadBytes =
            ShareProtocolConstants.binaryFrameByteLimit - fixedHeaderBytes - 1

        var rowSpans: [[String: Any]] = []
        var encoded = Data()
        var index = 0
        while encoded.count < targetPayloadBytes - 10_000 {
            rowSpans.append([
                "row": index % 500,
                "column": 0,
                "style_id": 0,
                "text": String(repeating: "x", count: 8_000),
            ])
            let object: [String: Any] = [
                "format": "cmux.render-grid.v1",
                "surface_id": pane,
                "state_seq": 1,
                "columns": 1_000,
                "rows": 500,
                "full": true,
                "row_spans": rowSpans,
            ]
            encoded = try JSONSerialization.data(withJSONObject: object)
            index += 1
        }

        let frame = try #require(
            ShareBinaryFrame.encode(
                kind: ShareProtocolConstants.binaryKindGrid,
                ws: workspace,
                pane: pane,
                payload: encoded
            )
        )
        #expect(frame.count < ShareProtocolConstants.binaryFrameByteLimit)
        let decoded = try #require(ShareBinaryFrame.decode(frame))
        let object = try #require(
            JSONSerialization.jsonObject(with: decoded.payload)
                as? [String: Any]
        )
        #expect(object["format"] as? String == "cmux.render-grid.v1")
        #expect((object["row_spans"] as? [[String: Any]])?.count == rowSpans.count)
    }
}
