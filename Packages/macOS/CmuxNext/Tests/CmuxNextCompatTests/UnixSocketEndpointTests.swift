import CmuxNextCompat
import Network
import Testing

/// ``NWEndpoint/unixSocket(path:)``: the one guard before `NWEndpoint.unix(path:)`, which traps on
/// a path that does not fit `sun_path` (issue #28492).
struct UnixSocketEndpointTests {
    @Test func theLimitIsSunPathLessItsNul() {
        #expect(NWEndpoint.unixSocketPathLimit == 103)
    }

    @Test func aPathAtTheLimitIsAnEndpointAndOneByteMoreIsRefused() throws {
        let fits = "/" + String(repeating: "a", count: NWEndpoint.unixSocketPathLimit - 1)
        #expect(try NWEndpoint.unixSocket(path: fits) == .unix(path: fits))
        let tooLong = fits + "a"
        #expect(throws: UnixSocketPathTooLong(path: tooLong)) { try NWEndpoint.unixSocket(path: tooLong) }
    }

    @Test func theLimitCountsBytesNotCharacters() {
        // 52 two-byte characters: 104 bytes in 53 characters with the slash.
        let path = "/" + String(repeating: "é", count: 52)
        #expect(throws: UnixSocketPathTooLong(path: path)) { try NWEndpoint.unixSocket(path: path) }
    }
}
