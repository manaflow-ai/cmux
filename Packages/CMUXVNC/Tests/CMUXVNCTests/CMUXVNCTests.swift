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
}
