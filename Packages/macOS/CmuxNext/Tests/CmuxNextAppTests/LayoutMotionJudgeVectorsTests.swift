import CmuxNextTestSupport
import Foundation
import Testing

/// The native judge of the layout-motion contract agrees with the pages' judge on every case in
/// schemas/layout-motion/vectors.json (webviews/test/motion-judge.test.ts holds the pages' judge to the same file).
@Suite struct LayoutMotionJudgeVectorsTests {
    @Test func theNativeJudgeAgreesWithEveryVector() throws {
        let contract = try LayoutMotionContract.load()
        let data = try Data(contentsOf: try LayoutMotionContract.repoRoot().appendingPathComponent("schemas/layout-motion/vectors.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(json["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let frames = (vector["frames"] as? [[String: Any]] ?? []).map(Self.frame)
            let verdict = judgeLayoutMotion(frames, contract: contract)
            #expect(verdict.undeclared == vector["undeclared"] as? Int, "\(name): \(verdict.moves)")
        }
    }

    @Test func everySurfaceDeclaresOnlyEventsTheContractNames() throws {
        let contract = try LayoutMotionContract.load()
        for (surface, events) in contract.moves {
            #expect(events.isSubset(of: contract.events), "\(surface) names an event the contract does not: \(events.subtracting(contract.events))")
        }
        for surface in ["sidebar-row", "sidebar-badge", "sidebar-list"] { #expect(contract.moves[surface] != nil, "no \(surface) surface") }
    }

    private static func frame(_ json: [String: Any]) -> LayoutMotionFrame {
        var samples: [String: LayoutMotionSample] = [:]
        for (id, value) in json["samples"] as? [String: [String: Any]] ?? [:] {
            let box = (value["box"] as? [Double]) ?? [0, 0, 0, 0]
            samples[id] = LayoutMotionSample(
                label: id, surface: value["surface"] as? String ?? "tracked",
                box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
                targeted: value["targeted"] as? Bool ?? false, after: value["after"] as? Bool ?? false,
                before: value["before"] as? Bool ?? false, animating: value["animating"] as? Bool ?? false
            )
        }
        let declared = (json["declared"] as? [[String: Any]] ?? []).map {
            LayoutMotionDeclaration(key: $0["key"] as? Int ?? 0, event: $0["event"] as? String ?? "",
                                    scope: LayoutMotionDeclaration.Scope(rawValue: $0["scope"] as? String ?? "all") ?? .all,
                                    once: $0["once"] as? Bool ?? false)
        }
        return LayoutMotionFrame(samples: samples, declared: declared)
    }
}
