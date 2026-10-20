import Foundation
import Testing
@testable import CmuxNextChromiumRuntime

/// The pin an app build ships (`cef-runtime.json`): what it accepts, and what
/// it refuses before anything is downloaded.
struct ChromiumRuntimePinTests {
    static let valid = """
    {"schema": 1, "key": "0123456789abcdef", "cef": "154.0.28", "chromium": "154.0.8037.58",
     "shim_abi": "abi-1", "sha256": "\(String(repeating: "ab", count: 32))", "size": 1000,
     "url": "https://files-next.cmux.com/cef-runtime/0123456789abcdef/cef-runtime.tar.xz",
     "team_id": "ABCDE12345", "wrapper": "cmux NIGHTLY Chromium.app"}
    """

    @Test func decodesTheReleaseShape() throws {
        let pin = try ChromiumRuntimePin.decode(Data(Self.valid.utf8))
        #expect(pin.key == "0123456789abcdef")
        #expect(pin.shimABI == "abi-1")
        #expect(pin.teamID == "ABCDE12345")
        #expect(pin.wrapper == "cmux NIGHTLY Chromium.app")
        #expect(pin.size == 1000)
    }

    @Test(arguments: [
        ("\"key\": \"0123456789abcdef\"", "\"key\": \"../../../etc\"", ChromiumRuntimePin.Invalid.key),
        ("\"sha256\": \"\(String(repeating: "ab", count: 32))\"", "\"sha256\": \"short\"", .sha256),
        ("\"size\": 1000", "\"size\": 0", .size),
        ("https://files-next.cmux.com", "http://files-next.cmux.com", .url),
        ("https://files-next.cmux.com", "file:///tmp", .url),
        ("\"wrapper\": \"cmux NIGHTLY Chromium.app\"", "\"wrapper\": \"../Chromium.app\"", .wrapper),
        ("\"wrapper\": \"cmux NIGHTLY Chromium.app\"", "\"wrapper\": \"Chromium\"", .wrapper),
        ("\"team_id\": \"ABCDE12345\"", "\"team_id\": \"abc; rm\"", .teamID),
        ("\"schema\": 1", "\"schema\": 2", .schema(2)),
    ])
    func refusesABadValue(original: String, replacement: String, expected: ChromiumRuntimePin.Invalid) throws {
        let text = Self.valid.replacingOccurrences(of: original, with: replacement)
        #expect(text != Self.valid)
        #expect(throws: expected) { try ChromiumRuntimePin.decode(Data(text.utf8)) }
    }

    @Test func plainHTTPOnlyToLoopback() throws {
        let text = Self.valid.replacingOccurrences(of: "https://files-next.cmux.com", with: "http://127.0.0.1:8123")
        #expect(try ChromiumRuntimePin.decode(Data(text.utf8)).url.port == 8123)
    }

    @Test func aDevPackHasNoTeam() throws {
        let text = Self.valid.replacingOccurrences(of: "\"team_id\": \"ABCDE12345\", ", with: "")
        #expect(try ChromiumRuntimePin.decode(Data(text.utf8)).teamID == nil)
    }

    @Test func bundledReadsTheResourcesFolder() throws {
        let folder = try TemporaryFolder()
        #expect(ChromiumRuntimePin.bundled(in: folder.url) == nil)
        try Data(Self.valid.utf8).write(to: folder.url.appending(path: ChromiumRuntimePin.resourceName))
        #expect(ChromiumRuntimePin.bundled(in: folder.url)?.key == "0123456789abcdef")
    }
}
