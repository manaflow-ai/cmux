#if os(iOS) && DEBUG
import CmuxMobileLinkFFI
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// The key-to-frame probe through the real bindings: each key is matched to the first frame
/// whose marker shows the next counter, and probe.json carries the screen-share-fast numbers.
@Suite(.timeLimit(.minutes(1))) struct ScreenKeyToFrameTests {
    static func lumas(_ value: UInt16) -> Data {
        Data((0 ..< 16).map { (value >> $0) & 1 == 1 ? 235 : 16 } + [235, 16, 235, 16])
    }

    /// A host that bumps the marker 5 ms after each key.
    final class EchoHost: KeyToFrameInput, @unchecked Sendable {
        let probe: KeyToFrameProbe
        private let lock = NSLock()
        private var value: UInt16
        init(probe: KeyToFrameProbe, value: UInt16) { self.probe = probe; self.value = value }
        func key() {
            let next = lock.withLock { value &+= 1; return value }
            let sent = keyToFrameClockUs()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { [probe] in
                _ = probe.frame(width: 640, height: 400, lumas: ScreenKeyToFrameTests.lumas(next),
                                decodedUs: sent + 4000, presentedUs: sent + 9000)
            }
        }
        func click(x: UInt32, y: UInt32) { key() }
    }

    @Test func probeJsonHasPresentedPercentiles() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let k2f = try #require(ScreenKeyToFrame(environment: ["CMUX_K2F_MARKER": "0.05,0", "CMUX_K2F_SAMPLES": "4", "CMUX_K2F_OUT": out]))
        #expect(k2f.probe.markerPoints(width: 640, height: 400).count == 20)
        #expect(k2f.probe.frame(width: 640, height: 400, lumas: Self.lumas(7), decodedUs: 1, presentedUs: 1) == 7)
        let text = try k2f.probe.run(input: EchoHost(probe: k2f.probe, value: 7), mode: "key", samples: 4, outDir: out, metaJson: "{}")
        let probe = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(probe["schema"] as? String == "cmux.screen-share-fast/1")
        let presented = try #require(probe["presented_ms"] as? [String: Any])
        #expect(presented["n"] as? Int == 4)
        #expect((presented["p50"] as? Double ?? 0) >= 9)
        #expect(FileManager.default.fileExists(atPath: out + "/probe.json"))
    }
}
#endif
