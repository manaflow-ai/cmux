import Testing
@testable import CmuxAgentBrands

/// The platform-neutral model: the resolver, the generated catalog and the size variants.
/// It runs on macOS and on Linux (scripts/cmux-next/linux/swift-shared.sh --only CmuxAgentBrands).
@Suite struct AgentBrandCatalogTests {
    @Test func resolvesEveryCaseSharedWithTheTypeScriptResolver() {
        for (input, brand) in AgentBrandCatalog.resolutionCases {
            #expect(AgentBrandCatalog.brand(for: input) == brand, "\(input)")
        }
    }

    @Test func nilAndBlankIdsHaveNoBrand() {
        #expect(AgentBrandCatalog.brand(for: nil) == nil)
        #expect(AgentBrandCatalog.brand(for: "   ") == nil)
        #expect(AgentBrandCatalog.spec(forAgent: nil) == nil)
    }

    @Test func aKnownIdWithoutAMarkResolvesToNoBrand() {
        #expect(AgentBrandCatalog.lookup["prime-agent"] == .some(nil))
        #expect(AgentBrandCatalog.brand(for: "prime-agent") == nil)
        #expect(AgentBrandCatalog.spec(forAgent: "campfire") == nil)
    }

    @Test func candidatesTryTheWholeIdThenItsParts() {
        #expect(AgentBrandCatalog.candidates("  ACP:/usr/bin/Codex-ACP ") == ["acp:/usr/bin/codex-acp", "/usr/bin/codex-acp", "codex-acp", "codex"])
        #expect(AgentBrandCatalog.candidates("").isEmpty)
    }

    @Test func everyBrandHasAMarkAndEveryMarkedAgentResolvesToIt() {
        for brand in AgentBrandID.allCases {
            #expect(AgentBrandCatalog.spec(for: brand) != nil, "\(brand)")
        }
        #expect(AgentBrandCatalog.specs.count == AgentBrandID.allCases.count)
        for agent in AgentBrandCatalog.agents {
            #expect(AgentBrandCatalog.brand(for: agent.id) == agent.brand, "\(agent.id)")
            if let brand = agent.brand {
                #expect(AgentBrandCatalog.spec(for: brand) != nil, "\(agent.id)")
            }
        }
    }

    @Test func smallArtReplacesTheMarkOnlyAtOrBelowTheSmallSize() throws {
        let spec = try #require(AgentBrandCatalog.specs.values.first { $0.small != nil })
        let small = try #require(spec.small)
        let atSmall = spec.variant(forPointSize: AgentBrandCatalog.smallPointSize)
        #expect(atSmall.viewBox == small.viewBox)
        #expect(atSmall.paths == small.paths)
        #expect(atSmall.small == nil)
        #expect(atSmall.overlays.isEmpty)
        #expect(atSmall.tone == spec.tone)
        #expect(spec.variant(forPointSize: AgentBrandCatalog.smallPointSize + 1) == spec)

        let plain = try #require(AgentBrandCatalog.specs.values.first { $0.small == nil })
        #expect(plain.variant(forPointSize: 1) == plain)
        #expect(AgentBrandCatalog.spec(forAgent: "claude", pointSize: 64) == AgentBrandCatalog.spec(for: .claude))
    }

    /// The renderer reads absolute M, L, C and Z only, with whole argument groups; a path outside that
    /// grammar draws nothing. Checked here without Core Graphics, so it runs on Linux too.
    @Test func everyPathUsesTheRendererGrammar() {
        var paths: [(String, AgentBrandPathSpec)] = []
        for (brand, spec) in AgentBrandCatalog.specs {
            paths += spec.paths.map { (brand.rawValue, $0) }
            paths += (spec.small?.paths ?? []).map { (brand.rawValue + ".small", $0) }
        }
        #expect(!paths.isEmpty)
        for (name, path) in paths {
            #expect(isRendererPath(path.d), "\(name): \(path.d.prefix(40))")
        }
    }
}

/// The renderer's path grammar (AgentBrandRenderer.path in CmuxAgentBrandsUI), without building a CGPath.
private func isRendererPath(_ d: String) -> Bool {
    var groups: [(command: Character, numbers: Int)] = []
    var token = ""
    func flush() -> Bool {
        guard !token.isEmpty else { return true }
        guard Double(token) != nil, !groups.isEmpty else { return false }
        groups[groups.count - 1].numbers += 1
        token = ""
        return true
    }
    for character in d {
        if character.isLetter && character != "e" && character != "E" {
            guard flush(), "MLCZ".contains(character) else { return false }
            groups.append((character, 0))
        } else if character == " " || character == "," {
            guard flush() else { return false }
        } else if character == "-" && !token.isEmpty && token.last != "e" && token.last != "E" {
            guard flush() else { return false }
            token = "-"
        } else {
            token.append(character)
        }
    }
    guard flush(), groups.first?.command == "M" else { return false }
    return groups.allSatisfy { group in
        switch group.command {
        case "Z": group.numbers == 0
        case "C": group.numbers > 0 && group.numbers.isMultiple(of: 6)
        default: group.numbers > 0 && group.numbers.isMultiple(of: 2)
        }
    }
}
