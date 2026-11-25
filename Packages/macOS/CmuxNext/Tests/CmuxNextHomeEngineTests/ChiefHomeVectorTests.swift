@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The app resolves every Chief home of `schemas/chief-home/vectors.json` as the `cmux` CLI does (cmux-tui
/// `cli/chief/home.rs` reads the same file). Two Debug copies of one bundle id with their own `CMUX_TAG` get two
/// homes (their build keys); a tagged DEV build, NIGHTLY and cmux NEXT keep the homes they had.
@Suite struct ChiefHomeVectorTests {
    struct Case: Decodable {
        let name: String
        let user_home: String
        let tag: String?
        let environment: [String: String]
        let root: String
        let session: String
        let isolated: Bool?
    }

    struct Vectors: Decodable { let cases: [Case] }

    static func vectors() throws -> [Case] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../..").standardizedFileURL
        let data = try Data(contentsOf: repo.appendingPathComponent("schemas/chief-home/vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data).cases
    }

    @Test func everyVectorResolvesAsTheCLIResolvesIt() throws {
        let cases = try Self.vectors()
        #expect(cases.count >= 12)
        for vector in cases {
            let home = ChiefHome.resolve(tag: vector.tag, environment: vector.environment,
                                         userHome: URL(fileURLWithPath: vector.user_home, isDirectory: true),
                                         bundleID: vector.environment["CMUX_BUNDLE_ID"], isDebugBuild: false)
            #expect(home.root.standardizedFileURL.path == vector.root, "\(vector.name)")
            #expect(home.session == vector.session, "\(vector.name)")
            if let isolated = vector.isolated { #expect(home.isolated == isolated, "\(vector.name)") }
        }
    }
}
