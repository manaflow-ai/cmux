import Foundation
import Testing

/// The benchmark screen replays copies of `schemas/terminal-corpus` bundled
/// with the iOS app (SwiftPM resources cannot point outside the target).
/// After `generate.py` changes the corpus, refresh the copies; this fails
/// until they match.
@Suite struct CorpusFixtureDriftTests {
    @Test func bundledCopiesMatchTheCorpus() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Fixtures.bundled.path).sorted()
        #expect(names.contains("manifest.json"))
        #expect(names.count >= 4)
        for name in names {
            let bundled = try Data(contentsOf: Fixtures.bundled.appendingPathComponent(name))
            let source = try Data(contentsOf: Fixtures.schemas.appendingPathComponent(name))
            #expect(bundled == source, "\(name) differs from schemas/terminal-corpus; copy it again")
        }
    }
}
