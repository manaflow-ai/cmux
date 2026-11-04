import Foundation
@testable import CmuxNextMacScreen
import Testing

/// The Mac Screen reads the lines of `cmux rd serve|connect` the way the host means them. Every
/// golden vector of cmux-rd-proto (tests/vectors/app_lines.json: the host prints its `AppLine`
/// type, cmux-rd-ffi's line reader reads the same file) reads here as its `want`: the fields it
/// holds, or no line at all.
@Suite struct MacScreenRdLineTests {
    static func vectors() -> [[String: Any]] {
        let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let file = repo.appendingPathComponent("cmux-tui/crates/cmux-rd-proto/tests/vectors/app_lines.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    /// A read line in the vectors' `want` shape.
    static func shape(_ line: MacScreenRdMessage) -> NSDictionary {
        var out: [String: Any] = [:]
        if let key = line.key { out["key"] = key }
        if let candidate = line.candidate { out["candidate"] = candidate }
        if line.candidatesDone == true { out["candidates_done"] = true }
        if line.connected == true { out["connected"] = true }
        if line.listening == true { out["listening"] = true }
        if let ended = line.ended { out["ended"] = ended }
        if let path = line.path {
            out["path"] = ["kind": path.kind.map { $0 as Any } ?? NSNull(), "rtt_ms": path.rttMs.map { $0 as Any } ?? NSNull()]
        }
        if let displays = line.displays { out["displays"] = displays.map { $0.map(Int.init) } }
        if let current = line.current { out["current"] = current }
        if let error = line.error { out["error"] = error }
        return out as NSDictionary
    }

    @Test func everyGoldenVectorReadsAsItsWant() {
        let vectors = Self.vectors()
        #expect(vectors.count >= 10)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let text = vector["line"] as? String ?? ""
            let read = try? JSONDecoder().decode(MacScreenRdMessage.self, from: Data(text.utf8))
            if let want = vector["want"] as? [String: Any] {
                #expect(read.map(Self.shape) == want as NSDictionary, "\(name)")
            } else {
                #expect(read == nil, "\(name)")
            }
        }
    }
}
