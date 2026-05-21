import XCTest
@testable import CMUXVNC

final class CMUXVNCTests: XCTestCase {
    func testManifestExpandsMacMiniClusterSessionsOnly() throws {
        let json = """
        {
          "default_password": "fallback",
          "hosts": [
            { "name": "builder", "prefix": "builder", "sessions": 2, "tag": "tag:macbuilder" },
            { "name": "mac3", "ssh": "admin@mac3", "prefix": "mac3", "sessions": 2, "tag": "tag:mac-mini-cluster" }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MacfleetManifest.self, from: Data(json.utf8))
        let sessions = manifest.expandedSessions()

        XCTAssertEqual(sessions.map(\.name), ["mac3-1", "mac3-2"])
        XCTAssertEqual(sessions.map(\.username), ["cmuxvnc", "cmuxvnc2"])
        XCTAssertEqual(sessions.map(\.address), ["mac3-1", "mac3-2"])
        XCTAssertEqual(sessions.map(\.defaultPassword), ["fallback", "fallback"])
    }

    func testManifestSupportsExplicitSessions() throws {
        let json = """
        {
          "hosts": [
            {
              "name": "studio",
              "prefix": "studio",
              "sessions": [
                { "index": 3, "name": "studio-custom", "host": "studio-vnc", "port": 5901, "username": "viewer", "password": "session" }
              ],
              "tag": "tag:mac-mini-cluster"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MacfleetManifest.self, from: Data(json.utf8))
        let session = try XCTUnwrap(manifest.expandedSessions().first)

        XCTAssertEqual(session.name, "studio-custom")
        XCTAssertEqual(session.address, "studio-vnc")
        XCTAssertEqual(session.port, 5901)
        XCTAssertEqual(session.username, "viewer")
        XCTAssertEqual(session.sessionPassword, "session")
    }

    func testExplicitSessionTagOverridesHostTag() throws {
        let json = """
        {
          "hosts": [
            {
              "name": "mixed",
              "prefix": "mixed",
              "tag": "tag:macbuilder",
              "sessions": [
                { "name": "mixed-builder", "tag": "tag:macbuilder" },
                { "name": "mixed-mini", "tag": "tag:mac-mini-cluster" }
              ]
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MacfleetManifest.self, from: Data(json.utf8))

        XCTAssertEqual(manifest.expandedSessions().map(\.name), ["mixed-mini"])
    }

    func testCountSessionsUseHostPasswordAsDefaultFallback() throws {
        let json = """
        {
          "default_password": "manifest",
          "hosts": [
            {
              "name": "mac3",
              "prefix": "mac3",
              "password": "host",
              "sessions": 2,
              "tag": "tag:mac-mini-cluster"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MacfleetManifest.self, from: Data(json.utf8))
        let sessions = manifest.expandedSessions()

        XCTAssertEqual(sessions.map(\.defaultPassword), ["host", "host"])
    }

    func testEmptyHostPasswordDoesNotMaskDefaultFallback() throws {
        let json = """
        {
          "default_password": "manifest",
          "hosts": [
            {
              "name": "mac3",
              "prefix": "mac3",
              "password": "",
              "default_password": "host-default",
              "sessions": 1,
              "tag": "tag:mac-mini-cluster"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(MacfleetManifest.self, from: Data(json.utf8))
        let session = try XCTUnwrap(manifest.expandedSessions().first)

        XCTAssertEqual(session.sessionPassword, "")
        XCTAssertEqual(session.defaultPassword, "host-default")
        XCTAssertEqual(
            VNCCredentialResolver.resolve(session: session, keychainPassword: nil),
            VNCResolvedCredential(username: "cmuxvnc", password: "host-default", source: .defaultPassword)
        )
    }

    func testCredentialPrecedence() {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1",
            port: 5900,
            username: "cmuxvnc",
            sessionPassword: "session",
            defaultPassword: "fallback",
            tag: "tag:mac-mini-cluster",
            index: 1
        )

        XCTAssertEqual(
            VNCCredentialResolver.resolve(session: session, keychainPassword: "keychain"),
            VNCResolvedCredential(username: "cmuxvnc", password: "keychain", source: .keychain)
        )
        XCTAssertEqual(
            VNCCredentialResolver.resolve(session: session, keychainPassword: nil),
            VNCResolvedCredential(username: "cmuxvnc", password: "session", source: .sessionPassword)
        )
    }

    func testSessionPersistenceSnapshotDropsPasswords() throws {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1",
            port: 5900,
            username: "cmuxvnc",
            sessionPassword: "session",
            defaultPassword: "fallback",
            tag: "tag:mac-mini-cluster",
            index: 1
        )

        let snapshot = session.nonSecretSnapshot
        let decoded = try JSONDecoder().decode(
            MacfleetVNCSession.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.name, "mac3-1")
        XCTAssertNil(decoded.sessionPassword)
        XCTAssertNil(decoded.defaultPassword)
    }

    func testConnectionIdentityIgnoresPasswordFields() {
        let session = MacfleetVNCSession(
            name: "mac3-1",
            hostName: "mac3",
            address: "mac3-1",
            port: 5900,
            username: "cmuxvnc",
            sessionPassword: "session",
            defaultPassword: "fallback",
            tag: "tag:mac-mini-cluster",
            index: 1
        )

        XCTAssertTrue(session.nonSecretSnapshot.hasSameConnectionIdentity(as: session))
        XCTAssertNotEqual(session.nonSecretSnapshot, session)
    }

    func testFrameValidationRejectsInvalidFrames() {
        let valid = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 10,
            height: 10,
            framebufferWidth: 20,
            framebufferHeight: 20,
            stride: 40
        )
        XCTAssertNil(VNCFrameValidator.validate(header: valid, payloadByteCount: 400))

        var outOfBounds = valid
        outOfBounds.x = 15
        XCTAssertEqual(
            VNCFrameValidator.validate(header: outOfBounds, payloadByteCount: 400),
            .rectOutOfBounds
        )

        XCTAssertEqual(
            VNCFrameValidator.validate(header: valid, payloadByteCount: 4),
            .payloadByteCountMismatch(expected: 400, actual: 4)
        )

        var hugeWidth = valid
        hugeWidth.width = Int.max
        XCTAssertEqual(
            VNCFrameValidator.validate(header: hugeWidth, payloadByteCount: 400),
            .rectOutOfBounds
        )

        var hugeX = valid
        hugeX.x = Int.max
        XCTAssertEqual(
            VNCFrameValidator.validate(header: hugeX, payloadByteCount: 400),
            .rectOutOfBounds
        )
    }

    func testFrameBlitterCopiesPartialFrameIntoFramebuffer() {
        var framebuffer = Data(repeating: 0, count: 3 * 2 * 4)
        let header = VNCFrameHeader(
            sequence: 1,
            x: 1,
            y: 0,
            width: 2,
            height: 2,
            framebufferWidth: 3,
            framebufferHeight: 2,
            stride: 8
        )
        let payload = Data([
            1, 2, 3, 4, 5, 6, 7, 8,
            9, 10, 11, 12, 13, 14, 15, 16
        ])

        XCTAssertTrue(
            VNCFrameBlitter.copyBGRAFrame(
                header: header,
                payload: payload,
                into: &framebuffer,
                framebufferWidth: 3,
                framebufferHeight: 2
            )
        )
        XCTAssertEqual(
            Array(framebuffer),
            [
                0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8,
                0, 0, 0, 0, 9, 10, 11, 12, 13, 14, 15, 16
            ]
        )
    }

    func testFrameBlitterRejectsInvalidPayload() {
        var framebuffer = Data(repeating: 0, count: 4)
        let header = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 1,
            framebufferHeight: 1,
            stride: 4
        )

        XCTAssertFalse(
            VNCFrameBlitter.copyBGRAFrame(
                header: header,
                payload: Data(),
                into: &framebuffer,
                framebufferWidth: 1,
                framebufferHeight: 1
            )
        )
        XCTAssertEqual(framebuffer, Data(repeating: 0, count: 4))
    }

    func testFrameComposerPublishesFullFramesInInputOrder() throws {
        var composer = VNCFramebufferComposer()
        let firstHeader = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 8
        )
        _ = try XCTUnwrap(composer.apply(
            header: firstHeader,
            payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
        ))

        let secondHeader = VNCFrameHeader(
            sequence: 2,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 4
        )
        let composed = try XCTUnwrap(composer.apply(
            header: secondHeader,
            payload: Data([9, 10, 11, 12])
        ))

        XCTAssertEqual(composed.header.sequence, 2)
        XCTAssertEqual(composed.header.x, 0)
        XCTAssertEqual(composed.header.width, 2)
        XCTAssertEqual(composed.header.stride, 8)
        XCTAssertEqual(Array(composed.payload), [9, 10, 11, 12, 5, 6, 7, 8])
    }

    func testFrameComposerReturnsStablePayloadsAfterLaterUpdates() throws {
        var composer = VNCFramebufferComposer()
        let fullFrame = VNCFrameHeader(
            sequence: 1,
            x: 0,
            y: 0,
            width: 2,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 8
        )
        let first = try XCTUnwrap(composer.apply(
            header: fullFrame,
            payload: Data([1, 2, 3, 4, 5, 6, 7, 8])
        ))

        let partialFrame = VNCFrameHeader(
            sequence: 2,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 2,
            framebufferHeight: 1,
            stride: 4
        )
        _ = try XCTUnwrap(composer.apply(
            header: partialFrame,
            payload: Data([9, 10, 11, 12])
        ))

        XCTAssertEqual(Array(first.payload), [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testIPCFrameRoundTrip() throws {
        let header = VNCFrameHeader(
            sequence: 7,
            x: 1,
            y: 2,
            width: 2,
            height: 2,
            framebufferWidth: 4,
            framebufferHeight: 4,
            stride: 8
        )
        let payload = Data(repeating: 0xab, count: 16)
        let encoded = try VNCIPCCodec.encodeFrame(header: header, payload: payload)
        var decoder = VNCIPCStreamDecoder()
        XCTAssertEqual(try decoder.append(encoded), [.frame(header, payload)])
    }

    func testIPCControlKeyRoundTrip() throws {
        let control = VNCControlMessage(kind: "key", text: "c", isDown: true, keyCode: 8)
        let encoded = try VNCIPCCodec.encodeControl(control)
        var decoder = VNCIPCStreamDecoder()

        XCTAssertEqual(try decoder.append(encoded), [.control(control)])
    }

    func testMacKeyCodeTranslatorMapsPrintableANSIKeys() {
        XCTAssertEqual(VNCMacKeyCodeTranslator.printableCharacters(forKeyCode: 8), "c")
        XCTAssertEqual(VNCMacKeyCodeTranslator.printableCharacters(forKeyCode: 18), "1")
        XCTAssertEqual(VNCMacKeyCodeTranslator.printableCharacters(forKeyCode: 47), ".")
        XCTAssertNil(VNCMacKeyCodeTranslator.printableCharacters(forKeyCode: 999))
    }

    func testIPCPointerMoveRoundTripWithoutButtonState() throws {
        let control = VNCControlMessage(kind: "pointer", x: 12, y: 34)
        let encoded = try VNCIPCCodec.encodeControl(control)
        var decoder = VNCIPCStreamDecoder()

        XCTAssertEqual(try decoder.append(encoded), [.control(control)])
    }

    func testIPCRejectsOutOfRangeFrameHeaderOnEncode() throws {
        let header = VNCFrameHeader(
            sequence: 7,
            x: 0,
            y: 0,
            width: 1,
            height: 1,
            framebufferWidth: 1,
            framebufferHeight: 1,
            stride: Int(UInt32.max) + 1
        )

        XCTAssertThrowsError(try VNCIPCCodec.encodeFrame(header: header, payload: Data(repeating: 0xab, count: 4))) { error in
            XCTAssertEqual(error as? VNCIPCError, .invalidFrameHeader)
        }
    }

    func testIPCRejectsEmptyPayloadAsInvalidFrameHeader() {
        XCTAssertThrowsError(try VNCIPCCodec.decodePayload(Data())) { error in
            XCTAssertEqual(error as? VNCIPCError, .invalidFrameHeader)
        }
    }

    func testIPCStreamDecoderDropsMalformedCompletePayloadBeforeThrowing() throws {
        let validControl = VNCControlMessage(kind: "key", isDown: true, keyCode: 40)
        let validFrame = try VNCIPCCodec.encodeControl(validControl)
        var decoder = VNCIPCStreamDecoder()

        XCTAssertThrowsError(try decoder.append(framedPayload([99]))) { error in
            XCTAssertEqual(error as? VNCIPCError, .unknownMessageType(99))
        }
        XCTAssertEqual(try decoder.append(validFrame), [.control(validControl)])
    }

    func testControlMessageQueueCoalescesPointerMovesAndCapsOtherInput() {
        var queue = VNCControlMessageQueue(maxMessages: 2)

        XCTAssertTrue(queue.append(VNCControlMessage(kind: "pointer", x: 1, y: 1)))
        XCTAssertTrue(queue.append(VNCControlMessage(kind: "pointer", x: 2, y: 2)))
        XCTAssertEqual(queue.messages, [VNCControlMessage(kind: "pointer", x: 2, y: 2)])

        XCTAssertTrue(queue.append(VNCControlMessage(kind: "key", isDown: true, keyCode: 12)))
        XCTAssertFalse(queue.append(VNCControlMessage(kind: "text", text: "overflow")))
        XCTAssertEqual(queue.messages.count, 2)
    }

    func testVisibilityFrameGateDropsHiddenUpdatesAndRefreshesOnShow() {
        var gate = VNCVisibilityFrameGate()

        XCTAssertEqual(gate.nextUpdateSequence(), 1)
        XCTAssertNil(gate.setVisible(false))
        XCTAssertNil(gate.nextUpdateSequence())
        XCTAssertNil(gate.nextUpdateSequence())
        XCTAssertEqual(gate.setVisible(true), 2)
        XCTAssertEqual(gate.nextUpdateSequence(), 3)
    }

    func testVisibilityFrameGateIgnoresUnchangedVisibility() {
        var gate = VNCVisibilityFrameGate()

        XCTAssertNil(gate.setVisible(true))
        XCTAssertEqual(gate.nextUpdateSequence(), 1)
        XCTAssertNil(gate.setVisible(false))
        XCTAssertNil(gate.setVisible(false))
        XCTAssertEqual(gate.setVisible(true), 2)
    }

    func testRestartPolicyCapsRestartsWithinWindow() {
        let policy = VNCHelperRestartPolicy(maxRestarts: 3, windowSeconds: 60)
        let now = Date(timeIntervalSince1970: 100)
        let restarts = [
            Date(timeIntervalSince1970: 60),
            Date(timeIntervalSince1970: 80),
            Date(timeIntervalSince1970: 99),
        ]

        XCTAssertFalse(policy.canRestart(previousRestartDates: restarts, now: now))
        XCTAssertTrue(policy.canRestart(previousRestartDates: restarts, now: Date(timeIntervalSince1970: 121)))
    }

    func testRestartPolicyIgnoresFutureRestartDates() {
        let policy = VNCHelperRestartPolicy(maxRestarts: 1, windowSeconds: 60)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(policy.canRestart(previousRestartDates: [Date(timeIntervalSince1970: 101)], now: now))
    }

    func testRestartPolicyClampsInvalidConfiguration() {
        let policy = VNCHelperRestartPolicy(maxRestarts: -1, windowSeconds: 0)
        XCTAssertEqual(policy.maxRestarts, 0)
        XCTAssertGreaterThan(policy.windowSeconds, 0)
        XCTAssertFalse(policy.canRestart(previousRestartDates: [], now: Date(timeIntervalSince1970: 100)))
    }

    private func framedPayload(_ payload: [UInt8]) -> Data {
        var output = Data()
        let length = UInt32(payload.count)
        output.append(UInt8((length >> 24) & 0xff))
        output.append(UInt8((length >> 16) & 0xff))
        output.append(UInt8((length >> 8) & 0xff))
        output.append(UInt8(length & 0xff))
        output.append(contentsOf: payload)
        return output
    }
}
