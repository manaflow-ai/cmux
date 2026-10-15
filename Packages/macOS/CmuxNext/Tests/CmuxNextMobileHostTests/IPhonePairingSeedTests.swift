import CmuxNextMobile
@testable import CmuxNextMobileHost
import Foundation
import Testing

/// The test-only pairing seed (DEBUG builds): a rig pairs a simulator without the
/// person-only prompt, only for the phones its file names.
@Suite struct IPhonePairingSeedTests {
    static let request = CnxPairRequest(phoneDeviceID: "AB12-phone", name: "cnx-e2e-ios26",
                                        identityKey: "04" + String(repeating: "aa", count: 64),
                                        approvalKey: "04" + String(repeating: "bb", count: 64))

    static func seed(_ json: String) throws -> (IPhonePairingSeed, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        return (IPhonePairingSeed(file: file), file)
    }

    @Test func onlyTheNamedPhoneIsTrusted() throws {
        let cases: [(String, Bool)] = [
            (#"{"devices":[{"id":"ab12-phone"}]}"#, true),
            (#"{"devices":[{"name":"cnx-e2e-ios26"}]}"#, true),
            (#"{"devices":[{"id":"ab12-phone","identityKey":"04\#(String(repeating: "aa", count: 64))"}]}"#, true),
            (#"{"devices":[{"id":"ab12-phone","identityKey":"04\#(String(repeating: "cc", count: 64))"}]}"#, false),
            (#"{"devices":[{"id":"other"}]}"#, false),
            (#"{"devices":[{}]}"#, false),
            ("not json", false),
        ]
        for (json, trusted) in cases {
            let (seed, file) = try Self.seed(json)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(seed.trusts(Self.request) == trusted, "\(json)")
        }
        #expect(!IPhonePairingSeed(file: URL(fileURLWithPath: "/nonexistent/seed.json")).trusts(Self.request))
    }

    @Test func theEnvironmentNamesAnAbsoluteFile() {
        #expect(IPhonePairingSeed.fromEnvironment([:]) == nil)
        #expect(IPhonePairingSeed.fromEnvironment([IPhonePairingSeed.environmentKey: "relative.json"]) == nil)
        #if DEBUG
        #expect(IPhonePairingSeed.fromEnvironment([IPhonePairingSeed.environmentKey: "/tmp/seed.json"])?.file.path == "/tmp/seed.json")
        #else
        #expect(IPhonePairingSeed.fromEnvironment([IPhonePairingSeed.environmentKey: "/tmp/seed.json"]) == nil)
        #endif
    }
}
