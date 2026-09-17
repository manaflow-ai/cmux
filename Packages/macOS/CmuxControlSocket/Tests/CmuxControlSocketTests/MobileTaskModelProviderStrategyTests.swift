import Foundation
import Testing
@testable import CmuxControlSocket

private actor MobileTaskModelStrategyProbe {
    private(set) var commands: [(String, Duration)] = []
    private(set) var readPaths: [String] = []
    var commandOutput: String?
    var files: [String: Data] = [:]

    func run(_ command: String, timeout: Duration) -> String? {
        commands.append((command, timeout))
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

    @Test func openCodeDiscoveryReplacesCuratedModelsAndKeepsCuratedNames() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput("""
        openai/gpt-5.5
        opencode/big-pickle
        """)
        let strategy = makeStrategy(probe: probe)

        let result = await strategy.models(for: .openCode)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(id: "openai/gpt-5.5", displayName: "GPT-5.5"),
                MobileTaskModel(
                    id: "opencode/big-pickle",
                    displayName: "opencode/big-pickle"
                ),
            ],
            source: .discovered
        ))
        let commands = await probe.commands
        #expect(commands.count == 1)
        #expect(commands.first?.0 == "opencode models")
        #expect(commands.first?.1 == .seconds(5))
        #expect(await probe.readPaths.isEmpty)
    }

    @Test func emptyOrFailedOpenCodeDiscoveryFallsBackToCuratedModels() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput("\n \n")
        let strategy = makeStrategy(probe: probe)
        #expect(
            await strategy.models(for: .openCode)
                == MobileTaskModelListResult(
                    models: MobileTaskModelProvider.openCode.curatedModels,
                    source: .fallback
                )
        )
        await probe.setCommandOutput(nil)
        #expect(
            await strategy.models(for: .openCode)
                == MobileTaskModelListResult(
                    models: MobileTaskModelProvider.openCode.curatedModels,
                    source: .fallback
                )
        )
    }

    @Test func codexPrependsNovelConfiguredModelWithoutSpawningACommand() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Users/tester/.codex/config.toml",
            data: Data("model = \"gpt-private-preview\"".utf8)
        )
        let result = await makeStrategy(probe: probe).models(for: .codex)

        #expect(result.source == .augmented)
        #expect(result.models.map(\.id) == [
            "gpt-private-preview",
            "gpt-5.6-luna",
            "gpt-5.6-sol",
            "gpt-5.5",
        ])
        #expect(result.models.first?.displayName == "gpt-private-preview")
        #expect(await probe.commands.isEmpty)
        #expect(await probe.readPaths == ["/Users/tester/.codex/config.toml"])
    }

    @Test func configuredCuratedModelMovesFirstAndIsDeduplicated() async {
        let codexProbe = MobileTaskModelStrategyProbe()
        await codexProbe.setFile(
            path: "/Users/tester/.codex/config.toml",
            data: Data("model = \"gpt-5.6-sol\"".utf8)
        )
        let codex = await makeStrategy(probe: codexProbe).models(for: .codex)
        #expect(codex.source == .augmented)
        #expect(codex.models.map(\.id) == [
            "gpt-5.6-sol",
            "gpt-5.6-luna",
            "gpt-5.5",
        ])
        #expect(codex.models.first?.displayName == "GPT-5.6 Sol")

        let claudeProbe = MobileTaskModelStrategyProbe()
        await claudeProbe.setFile(
            path: "/Users/tester/.claude/settings.json",
            data: Data(#"{"model":"claude-opus-4-8"}"#.utf8)
        )
        let claude = await makeStrategy(probe: claudeProbe).models(for: .claude)
        #expect(claude.source == .augmented)
        #expect(claude.models.map(\.id) == [
            "claude-opus-4-8",
            "claude-fable-5",
            "claude-sonnet-5",
            "claude-haiku-4-5",
        ])
        #expect(claude.models.first?.displayName == "Opus 4.8")
        #expect(await claudeProbe.commands.isEmpty)
    }

    @Test func missingConfigurationFilesReturnCuratedFallbacks() async {
        let probe = MobileTaskModelStrategyProbe()
        let strategy = makeStrategy(probe: probe)
        let codex = await strategy.models(for: .codex)
        let claude = await strategy.models(for: .claude)

        #expect(codex.source == .fallback)
        #expect(codex.models == MobileTaskModelProvider.codex.curatedModels)
        #expect(claude.source == .fallback)
        #expect(claude.models == MobileTaskModelProvider.claude.curatedModels)
        #expect(await probe.commands.isEmpty)
    }

    private func makeStrategy(
        probe: MobileTaskModelStrategyProbe
    ) -> MobileTaskModelProviderStrategy {
        MobileTaskModelProviderStrategy(
            homeDirectory: home,
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
    func setCommandOutput(_ output: String?) {
        commandOutput = output
    }

    func setFile(path: String, data: Data) {
        files[path] = data
    }
}
