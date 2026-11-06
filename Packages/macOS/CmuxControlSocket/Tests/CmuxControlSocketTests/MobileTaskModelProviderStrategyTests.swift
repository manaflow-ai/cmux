import Foundation
import Testing
@testable import CmuxControlSocket

private actor MobileTaskModelStrategyProbe {
    private(set) var commands: [(String, Duration)] = []
    private(set) var readPaths: [String] = []
    var commandOutput: String?
    var minimumCommandTimeout: Duration?
    var files: [String: Data] = [:]

    func run(_ command: String, timeout: Duration) -> String? {
        commands.append((command, timeout))
        if let minimumCommandTimeout, timeout < minimumCommandTimeout {
            return nil
        }
        return commandOutput
    }

    func read(_ url: URL) -> Data? {
        readPaths.append(url.path)
        return files[url.path]
    }
}

@Suite("Mobile task model provider strategy")
struct MobileTaskModelProviderStrategyTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func openCodeUsesAgentCommandAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setMinimumCommandTimeout(.seconds(20))
        await probe.setCommandOutput("""
        test-provider/host-next-999
        {"name":"Host Next 999","variants":{"high":{}}}
        test-provider/host-second-998
        {"name":"Host Second 998","variants":{"low":{}}}
        """)
        let strategy = makeStrategy(probe: probe)

        let result = await strategy.models(for: .openCode)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(
                    id: "test-provider/host-next-999",
                    displayName: "Host Next 999",
                    efforts: [MobileTaskModelEffort(id: "high", displayName: "High")]
                ),
                MobileTaskModel(
                    id: "test-provider/host-second-998",
                    displayName: "Host Second 998",
                    efforts: [MobileTaskModelEffort(id: "low", displayName: "Low")]
                ),
            ],
            source: .discovered
        ))
        let commands = await probe.commands
        #expect(commands.count == 1)
        #expect(commands.first?.0 == "opencode models --verbose")
        #expect(commands.first?.1 == .seconds(30))
        #expect(await probe.readPaths.isEmpty)
    }

    @Test func claudeUsesControlStreamAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput(#"{"type":"control_response","response":{"subtype":"success","request_id":"cmux-list-options","response":{"models":[{"value":"default","displayName":"Default","supportedEffortLevels":["low","medium","high"],"defaultEffortLevel":"medium"},{"value":"host-next-999","displayName":"Host Next 999"}]}}}"#)

        let result = await makeStrategy(probe: probe).models(for: .claude)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(id: "host-next-999", displayName: "Host Next 999"),
            ],
            source: .discovered,
            defaultModel: MobileTaskModel(
                id: "default",
                displayName: "Default",
                efforts: [
                    MobileTaskModelEffort(id: "low", displayName: "Low"),
                    MobileTaskModelEffort(id: "medium", displayName: "Medium"),
                    MobileTaskModelEffort(id: "high", displayName: "High"),
                ],
                defaultEffortID: "medium"
            )
        ))
        let commands = await probe.commands
        #expect(commands.count == 1)
        #expect(commands[0].0.contains("claude -p"))
        #expect(commands[0].0.contains("list_models"))
        #expect(commands[0].1 == .seconds(30))
        #expect(await probe.readPaths.isEmpty)
    }

    @Test func codexUsesDebugCatalogAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Users/tester/.codex/config.toml",
            data: Data(#"model = "gpt-5.6-sol""#.utf8)
        )
        await probe.setCommandOutput("""
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6 Sol",
              "visibility": "list",
              "supported_reasoning_levels": [
                {"effort":"low"},
                {"effort":"ultra"}
              ],
              "default_reasoning_level": "low"
            },
            {
              "slug": "gpt-hidden",
              "display_name": "Hidden",
              "visibility": "hidden"
            }
          ]
        }
        """)

        let result = await makeStrategy(probe: probe).models(for: .codex)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(
                    id: "gpt-5.6-sol",
                    displayName: "GPT-5.6 Sol",
                    efforts: [
                        MobileTaskModelEffort(id: "low", displayName: "Low"),
                        MobileTaskModelEffort(id: "ultra", displayName: "Ultra"),
                    ],
                    defaultEffortID: "low"
                ),
            ],
            source: .discovered,
            defaultModel: MobileTaskModel(
                id: "gpt-5.6-sol",
                displayName: "GPT-5.6 Sol",
                efforts: [
                    MobileTaskModelEffort(id: "low", displayName: "Low"),
                    MobileTaskModelEffort(id: "ultra", displayName: "Ultra"),
                ],
                defaultEffortID: "low"
            )
        ))
        #expect(await probe.commands.map(\.0) == ["exec codex debug models"])
        #expect(await probe.commands.map(\.1) == [.seconds(5)])
        #expect(await probe.readPaths == ["/Users/tester/.codex/config.toml"])
    }

    @Test func codexFallsBackToAgentOwnedCacheAfterDebugFailure() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Users/tester/.codex/models_cache.json",
            data: Data(#"{"models":[{"slug":"host-next-999","display_name":"Host Next 999","visibility":"list"},{"slug":"hidden-model","display_name":"Hidden","visibility":"hide"},{"slug":"internal-model","display_name":"Internal","visibility":"none"}]}"#.utf8)
        )

        let result = await makeStrategy(probe: probe).models(for: .codex)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(id: "host-next-999", displayName: "Host Next 999"),
            ],
            source: .discovered
        ))
        #expect(await probe.commands.map(\.0) == ["exec codex debug models"])
        #expect(await probe.readPaths == [
            "/Users/tester/.codex/models_cache.json",
            "/Users/tester/.codex/config.toml",
        ])
    }

    @Test func codexHonorsCustomExecutableAndCodexHome() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Volumes/work/codex-home/config.toml",
            data: Data(#"model = "host-next-999""#.utf8)
        )
        await probe.setCommandOutput(#"{"models":[{"slug":"host-next-999","display_name":"Host Next 999","visibility":"list"}]}"#)

        let result = await makeStrategy(
            probe: probe,
            environment: [
                "CODEX_HOME": "/Volumes/work/codex-home",
                "CMUX_CUSTOM_CODEX_PATH": "/opt/codex's bin/codex",
            ]
        ).models(for: .codex)

        let model = MobileTaskModel(id: "host-next-999", displayName: "Host Next 999")
        #expect(result == MobileTaskModelListResult(
            models: [model],
            source: .discovered,
            defaultModel: model
        ))
        #expect(await probe.commands.map(\.0) == [
            #"CODEX_HOME='/Volumes/work/codex-home' exec '/opt/codex'\''s bin/codex' debug models"#,
        ])
        #expect(await probe.readPaths == ["/Volumes/work/codex-home/config.toml"])
    }

    @Test func codexFallsBackToCustomCodexHomeCacheAndDefaultModel() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Users/tester/accounts/work/models_cache.json",
            data: Data(#"{"models":[{"slug":"host-next-999","display_name":"Host Next 999","visibility":"list"}]}"#.utf8)
        )
        await probe.setFile(
            path: "/Users/tester/accounts/work/config.toml",
            data: Data(#"model = "host-next-999""#.utf8)
        )

        let result = await makeStrategy(
            probe: probe,
            environment: ["CODEX_HOME": "~/accounts/work/"]
        ).models(for: .codex)

        let model = MobileTaskModel(id: "host-next-999", displayName: "Host Next 999")
        #expect(result == MobileTaskModelListResult(
            models: [model],
            source: .discovered,
            defaultModel: model
        ))
        #expect(await probe.commands.map(\.0) == [
            "CODEX_HOME='/Users/tester/accounts/work' exec codex debug models",
        ])
        #expect(await probe.readPaths == [
            "/Users/tester/accounts/work/models_cache.json",
            "/Users/tester/accounts/work/config.toml",
        ])
    }

    @Test func missingCustomCodexExecutableReportsProviderUnavailable() async {
        let probe = MobileTaskModelStrategyProbe()

        let result = await makeStrategy(
            probe: probe,
            environment: ["CMUX_CUSTOM_CODEX_PATH": "/opt/codex/bin/codex"]
        ).models(for: .codex)

        #expect(result.error == .providerUnavailable)
        #expect(await probe.commands.map(\.0) == [
            "exec '/opt/codex/bin/codex' debug models",
            "command -v '/opt/codex/bin/codex'",
        ])
        #expect(await probe.readPaths == ["/Users/tester/.codex/models_cache.json"])
    }

    @Test func failedAgentDiscoveryReturnsNoInventedValues() async {
        let probe = MobileTaskModelStrategyProbe()
        let strategy = makeStrategy(probe: probe)
        let codex = await strategy.models(for: .codex)
        let claude = await strategy.models(for: .claude)
        let openCode = await strategy.models(for: .openCode)

        #expect(codex.source == .fallback)
        #expect(codex.models.isEmpty)
        #expect(codex.error == .providerUnavailable)
        #expect(claude.source == .fallback)
        #expect(claude.models.isEmpty)
        #expect(claude.error == .providerUnavailable)
        #expect(openCode.source == .fallback)
        #expect(openCode.models.isEmpty)
        #expect(openCode.error == .providerUnavailable)
    }

    @Test func failedQueryIsDistinctFromMissingAgent() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput("")
        let strategy = makeStrategy(probe: probe)

        let codex = await strategy.models(for: .codex)
        let claude = await strategy.models(for: .claude)
        let openCode = await strategy.models(for: .openCode)

        #expect(codex.error == .queryFailed)
        #expect(claude.error == .queryFailed)
        #expect(openCode.error == .queryFailed)
    }

    private func makeStrategy(
        probe: MobileTaskModelStrategyProbe,
        environment: [String: String] = [:]
    ) -> MobileTaskModelProviderStrategy {
        MobileTaskModelProviderStrategy(
            homeDirectory: home,
            environment: environment,
            commandRunner: { command, timeout in
                await probe.run(command, timeout: timeout)
            },
            fileReader: { url in
                await probe.read(url)
            }
        )
    }
}

private extension MobileTaskModelStrategyProbe {
    func setMinimumCommandTimeout(_ timeout: Duration?) {
        minimumCommandTimeout = timeout
    }

    func setCommandOutput(_ output: String?) {
        commandOutput = output
    }

    func setFile(path: String, data: Data) {
        files[path] = data
    }
}
