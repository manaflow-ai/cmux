import CoreGraphics
import Testing
@testable import CmuxAgentBrands

@Suite struct AgentBrandCatalogTests {
    @Test func sharedResolutionCasesResolve() {
        for (input, expected) in AgentBrandCatalog.resolutionCases {
            #expect(AgentBrandCatalog.brand(for: input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func everySupportedAgentResolvesToItsBrand() {
        #expect(!AgentBrandCatalog.agents.isEmpty)
        for agent in AgentBrandCatalog.agents {
            #expect(AgentBrandCatalog.brand(for: agent.id) == agent.brand, "\(agent.id)")
            #expect(AgentBrandCatalog.brand(for: agent.id.uppercased()) == agent.brand, "\(agent.id) uppercased")
            if let brand = agent.brand {
                #expect(AgentBrandCatalog.spec(for: brand) != nil, "\(agent.id) has no mark")
            }
        }
    }

    @Test func requestedHarnessesHaveMarks() {
        // R79: Claude Code, Codex/ChatGPT, OpenCode, Pi, Hermes and the DeepSeek harness.
        for agent in ["claude", "codex", "chatgpt", "opencode", "pi", "hermes-agent", "dsh", "deepseek"] {
            #expect(AgentBrandCatalog.spec(forAgent: agent) != nil, "\(agent)")
        }
    }

    @Test func everyMarkParsesIntoItsViewBox() throws {
        #expect(AgentBrandID.allCases.count >= 20)
        for brand in AgentBrandID.allCases {
            let spec = try #require(AgentBrandCatalog.spec(for: brand), "\(brand)")
            let box = CGRect(x: spec.viewBox.x, y: spec.viewBox.y, width: spec.viewBox.width, height: spec.viewBox.height)
            var union = CGRect.null
            for item in spec.paths {
                let path = try #require(AgentBrandRenderer.path(item.d), "\(brand) path does not parse")
                union = union.union(path.boundingBoxOfPath)
            }
            // The artwork fills most of its view box. It may run past an edge where the owner's
            // framing crops it (Hermes Agent's portrait), but never sits in another coordinate space.
            let shown = union.intersection(box)
            #expect(!shown.isNull && shown.width * shown.height >= box.width * box.height * 0.4, "\(brand) art \(union) vs view box \(box)")
        }
    }

    /// R79: no mark is an unreadable dark shape at 16 pt. A traced picture (more than
    /// `tracedSegments` path segments) draws its owner's simpler `small` art there, and the
    /// art drawn at 16 pt is never a traced picture itself.
    @Test func everyBrandHasALegibleSmallVariant() throws {
        func segments(_ spec: AgentBrandSpec) -> Int {
            spec.paths.reduce(0) { $0 + $1.d.filter { "MLC".contains($0) }.count }
        }
        for brand in AgentBrandID.allCases {
            let spec = try #require(AgentBrandCatalog.spec(for: brand))
            let small = spec.variant(forPointSize: 16)
            if segments(spec) > AgentBrandCatalog.tracedSegments {
                #expect(small.paths != spec.paths, "\(brand) is a traced picture and needs small art")
            }
            #expect(segments(small) <= AgentBrandCatalog.tracedSegments, "\(brand) art at 16 pt has \(segments(small)) segments")
            let image = try #require(AgentBrandRenderer.image(small, pixelSize: 16, style: .mono, dark: true))
            let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            let alpha = try #require(context.data).bindMemory(to: UInt8.self, capacity: 1024)
            let inked = (0..<256).filter { alpha[$0 * 4 + 3] > 64 }.count
            #expect(inked >= 10, "\(brand) draws almost nothing at 16 px (\(inked) px)")
        }
        // Hermes Agent: the wing at 16 pt and below, the portrait above.
        let small = try #require(AgentBrandCatalog.spec(forAgent: "hermes-agent", pointSize: 12))
        let large = try #require(AgentBrandCatalog.spec(forAgent: "hermes-agent", pointSize: 32))
        #expect(small.paths != large.paths)
        #expect(AgentBrandCatalog.spec(forAgent: "hermes-agent", pointSize: 16)?.paths == small.paths)
    }

    @Test func parserRejectsMalformedData() {
        #expect(AgentBrandRenderer.path("") == nil)
        #expect(AgentBrandRenderer.path("M1 2L3") == nil)
        #expect(AgentBrandRenderer.path("M1 2Q3 4 5 6") == nil)
        #expect(AgentBrandRenderer.path("M0 0L-1.5 2e1Z") != nil)
    }
}
