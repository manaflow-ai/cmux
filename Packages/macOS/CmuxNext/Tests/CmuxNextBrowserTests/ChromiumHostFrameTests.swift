@testable import CmuxNextBrowser
import Foundation
import Testing

/// The wire between cmux and the Chromium host app: the same golden frame as
/// CEFShim/tests/chromium_host_wire_test.cpp, so the Swift and C++ sides agree.
@Suite struct ChromiumHostFrameTests {
    static let golden: [UInt8] = hexBytes(
        "05000000030000000a000000feffffffffffff7f0300000004000000ffffffff"
            + "00001000000000000807060504030201010000000000000061004100efbeadde")

    static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    static var goldenFrame: ChromiumHostFrame {
        var frame = ChromiumHostFrame(.key, v: [10, -2, Int32.max, 3, 4, -1], flags: 0x100000, t0: 0x0102030405060708,
                                      payload: Array("abc".utf8))
        frame.t1 = 1
        frame.ch = 0x61
        frame.unmod = 0x41
        frame.seq = 0xdeadbeef
        return frame
    }

    @Test func encodesTheGoldenFrame() {
        #expect(Self.goldenFrame.encoded() == Self.golden + Array("abc".utf8))
    }

    @Test func decodesTheGoldenFrame() throws {
        let bytes = Self.golden + Array("abc".utf8) + [9, 9]
        guard case .frame(let frame, let consumed) = ChromiumHostFrame.decode(bytes[...]) else {
            Issue.record("no frame")
            return
        }
        #expect(consumed == 67)
        #expect(frame == Self.goldenFrame)
        #expect(frame.kind == .key)
        #expect(frame.text == "abc")
    }

    @Test func waitsForTheRestOfAFrame() {
        let bytes = Self.golden + Array("ab".utf8)
        #expect(ChromiumHostFrame.decode(bytes[...]) == .needMore)
        #expect(ChromiumHostFrame.decode(Self.golden[0..<63]) == .needMore)
    }

    @Test func refusesAPayloadOverTheLimit() {
        var bytes = Self.golden
        let length = UInt32(ChromiumHostFrame.maxPayload + 1)
        for index in 0..<4 { bytes[4 + index] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(index))) }
        #expect(ChromiumHostFrame.decode(bytes[...]) == .invalid)
    }

    /// Remote Cocoa (fork API 37) kinds: the same numbers as chromium_host_wire.h.
    @Test func remoteCocoaKindsMatchTheHost() {
        #expect(ChromiumHostFrame.Kind.attach.rawValue == 11)
        #expect(ChromiumHostFrame.Kind.remoteServer.rawValue == 109)
        #expect(ChromiumHostFrame.Kind.remoteAttached.rawValue == 110)
        #expect(ChromiumHostFrame.Kind.unhandledKey.rawValue == 111)
    }

    /// A view id crosses as two 32-bit halves (v0 low, v1 high), as the host reassembles it.
    @Test func attachCarriesA64BitViewID() {
        let id: UInt64 = (1 << 62) + 7
        let frame = ChromiumHostFrame(.attach, v: .init(Int32(bitPattern: UInt32(truncatingIfNeeded: id)),
                                                        Int32(bitPattern: UInt32(truncatingIfNeeded: id >> 32))))
        guard case .frame(let decoded, _) = ChromiumHostFrame.decode(frame.encoded()[...]) else {
            Issue.record("no frame")
            return
        }
        let low = UInt64(UInt32(bitPattern: decoded.v[0]))
        let high = UInt64(UInt32(bitPattern: decoded.v[1]))
        #expect(low | (high << 32) == id)
    }

    /// A second host gets its own data folder (one browser process per folder) and the remote Cocoa switch.
    @Test func aRemoteVariantHasItsOwnDataFolder() {
        let base = ChromiumHostConfiguration(executable: URL(fileURLWithPath: "/h"), arguments: ["--framework=/f", "--root-cache=/r"])
        let variant = base.variant(suffix: "1", remoteCocoa: true)
        #expect(variant.arguments == ["--framework=/f", "--root-cache=/r-1", "--remote-cocoa"])
        #expect(base.variant(suffix: nil, remoteCocoa: false) == base)
    }

    @Test func keepsAnUnknownKind() {
        let frame = ChromiumHostFrame(rawKind: 999)
        guard case .frame(let decoded, _) = ChromiumHostFrame.decode(frame.encoded()[...]) else {
            Issue.record("no frame")
            return
        }
        #expect(decoded.rawKind == 999)
        #expect(decoded.kind == nil)
    }
}
