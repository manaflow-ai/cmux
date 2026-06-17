import XCTest
@testable import CmuxVNC

final class RFBProtocolTests: XCTestCase {
    // MARK: PixelFormat

    func testPixelFormatRoundTrip() {
        let format = RFBPixelFormat.cmuxBGRX
        let encoded = format.encoded()
        XCTAssertEqual(encoded.count, 16)
        let decoded = RFBPixelFormat(encoded[...])
        XCTAssertEqual(decoded, format)
    }

    func testCmuxFormatIsLittleEndianTrueColor() {
        let format = RFBPixelFormat.cmuxBGRX
        XCTAssertEqual(format.bitsPerPixel, 32)
        XCTAssertEqual(format.bytesPerPixel, 4)
        XCTAssertFalse(format.bigEndian)
        XCTAssertTrue(format.trueColor)
        XCTAssertEqual(format.redShift, 16)
        XCTAssertEqual(format.greenShift, 8)
        XCTAssertEqual(format.blueShift, 0)
    }

    // MARK: Client messages

    func testFramebufferUpdateRequestBytes() {
        let bytes = RFBClientMessage.framebufferUpdateRequest(
            incremental: true, x: 0, y: 0, width: 0x0102, height: 0x0304
        )
        XCTAssertEqual(bytes, [3, 1, 0, 0, 0, 0, 0x01, 0x02, 0x03, 0x04])
    }

    func testSetEncodingsBytes() {
        let bytes = RFBClientMessage.setEncodings([.raw, .copyRect])
        XCTAssertEqual(bytes, [2, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    func testPointerEventBytes() {
        let bytes = RFBClientMessage.pointerEvent(buttonMask: 0b1, x: 0x00FF, y: 0x0100)
        XCTAssertEqual(bytes, [5, 1, 0x00, 0xFF, 0x01, 0x00])
    }

    func testKeyEventBytes() {
        let bytes = RFBClientMessage.keyEvent(keysym: 0xFF0D, down: true)
        XCTAssertEqual(bytes, [4, 1, 0, 0, 0x00, 0x00, 0xFF, 0x0D])
    }

    // MARK: VNC authentication

    func testReverseBits() {
        XCTAssertEqual(VNCAuthentication.reverseBits(0x01), 0x80)
        XCTAssertEqual(VNCAuthentication.reverseBits(0x02), 0x40)
        XCTAssertEqual(VNCAuthentication.reverseBits(0x80), 0x01)
        XCTAssertEqual(VNCAuthentication.reverseBits(0xFF), 0xFF)
        XCTAssertEqual(VNCAuthentication.reverseBits(0x00), 0x00)
    }

    func testDesKeyTruncatesAndReverses() {
        let key = VNCAuthentication.desKey(from: "ABCDEFGHIJ")
        XCTAssertEqual(key.count, 8)
        XCTAssertEqual(key[0], VNCAuthentication.reverseBits(UInt8(ascii: "A")))
        XCTAssertEqual(key[7], VNCAuthentication.reverseBits(UInt8(ascii: "H")))
    }

    func testChallengeResponseIsSixteenBytesAndDeterministic() {
        let challenge = (0 ..< 16).map { UInt8($0) }
        let a = VNCAuthentication.challengeResponse(challenge: challenge, password: "secret")
        let b = VNCAuthentication.challengeResponse(challenge: challenge, password: "secret")
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(a, b)
    }

    func testChallengeResponseUsesECBPerBlock() {
        // In ECB mode the first output block depends only on the first input
        // block, so encrypting only the first 8 challenge bytes must reproduce
        // the first 8 bytes of the full 16-byte response.
        let challenge = (0 ..< 16).map { UInt8($0) }
        let full = VNCAuthentication.challengeResponse(challenge: challenge, password: "secret")
        let firstBlock = VNCAuthentication.challengeResponse(challenge: Array(challenge.prefix(8)), password: "secret")
        XCTAssertEqual(Array(full.prefix(8)), firstBlock)
    }

    func testDifferentPasswordsProduceDifferentResponses() {
        let challenge = [UInt8](repeating: 0xAB, count: 16)
        let a = VNCAuthentication.challengeResponse(challenge: challenge, password: "alpha")
        let b = VNCAuthentication.challengeResponse(challenge: challenge, password: "bravo")
        XCTAssertNotEqual(a, b)
    }

    // MARK: Handshake

    private func makeServerInitBytes(width: UInt16, height: UInt16, name: String) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)]
        bytes.append(contentsOf: RFBPixelFormat.cmuxBGRX.encoded())
        let nameBytes = Array(name.utf8)
        bytes.append(contentsOf: [0, 0, UInt8(nameBytes.count >> 8), UInt8(nameBytes.count & 0xFF)])
        bytes.append(contentsOf: nameBytes)
        return bytes
    }

    func testHandshakeNoneSecurity38() async throws {
        var stream = Array("RFB 003.008\n".utf8)
        stream.append(contentsOf: [1, 1])           // 1 security type: None
        stream.append(contentsOf: [0, 0, 0, 0])     // SecurityResult OK
        stream.append(contentsOf: makeServerInitBytes(width: 1024, height: 768, name: "screen"))

        let source = InMemoryByteSource(stream)
        let sink = InMemoryByteSink()
        let init0 = try await RFBHandshake().negotiate(source: source, sink: sink, password: nil)

        XCTAssertEqual(init0.width, 1024)
        XCTAssertEqual(init0.height, 768)
        XCTAssertEqual(init0.name, "screen")

        let written = await sink.contents()
        var expected = Array("RFB 003.008\n".utf8)
        expected.append(1) // chose None
        expected.append(1) // ClientInit shared flag
        XCTAssertEqual(written, expected)
    }

    func testHandshakeVNCAuth38() async throws {
        let challenge = (0 ..< 16).map { UInt8($0 &* 7 &+ 3) }
        var stream = Array("RFB 003.008\n".utf8)
        stream.append(contentsOf: [1, 2])           // 1 security type: VNC auth
        stream.append(contentsOf: challenge)        // 16-byte challenge
        stream.append(contentsOf: [0, 0, 0, 0])     // SecurityResult OK
        stream.append(contentsOf: makeServerInitBytes(width: 800, height: 600, name: "vm"))

        let source = InMemoryByteSource(stream)
        let sink = InMemoryByteSink()
        let init0 = try await RFBHandshake().negotiate(source: source, sink: sink, password: "hunter2")

        XCTAssertEqual(init0.width, 800)
        XCTAssertEqual(init0.height, 600)

        let written = await sink.contents()
        var expected = Array("RFB 003.008\n".utf8)
        expected.append(2) // chose VNC auth
        expected.append(contentsOf: VNCAuthentication.challengeResponse(challenge: challenge, password: "hunter2"))
        expected.append(1) // ClientInit
        XCTAssertEqual(written, expected)
    }

    func testHandshakeAuthFailureThrows() async {
        var stream = Array("RFB 003.008\n".utf8)
        stream.append(contentsOf: [1, 2])           // VNC auth
        stream.append(contentsOf: [UInt8](repeating: 0, count: 16)) // challenge
        stream.append(contentsOf: [0, 0, 0, 1])     // SecurityResult failed
        stream.append(contentsOf: [0, 0, 0, 7])     // reason length 7
        stream.append(contentsOf: Array("bad pwd".utf8))

        let source = InMemoryByteSource(stream)
        let sink = InMemoryByteSink()
        do {
            _ = try await RFBHandshake().negotiate(source: source, sink: sink, password: "x")
            XCTFail("expected failure")
        } catch let error as RFBError {
            XCTAssertEqual(error, .authenticationFailed("bad pwd"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHandshakePasswordRequiredWhenOnlyVNCOffered() async {
        var stream = Array("RFB 003.008\n".utf8)
        stream.append(contentsOf: [1, 2]) // only VNC auth offered
        let source = InMemoryByteSource(stream)
        let sink = InMemoryByteSink()
        do {
            _ = try await RFBHandshake().negotiate(source: source, sink: sink, password: nil)
            XCTFail("expected passwordRequired")
        } catch let error as RFBError {
            XCTAssertEqual(error, .passwordRequired)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
