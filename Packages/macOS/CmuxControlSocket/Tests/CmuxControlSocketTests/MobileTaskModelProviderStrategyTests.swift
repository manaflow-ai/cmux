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

    @Test func openCodeUsesAgentCommandAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput("""
        test-provider/host-next-999
        test-provider/host-second-998
        """)
        let strategy = makeStrategy(probe: probe)

        let result = await strategy.models(for: .openCode)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(
                    id: "test-provider/host-next-999",
                    displayName: "test-provider/host-next-999"
                ),
                MobileTaskModel(
                    id: "test-provider/host-second-998",
                    displayName: "test-provider/host-second-998"
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

    @Test func claudeUsesControlStreamAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setCommandOutput(#"{"type":"control_response","response":{"subtype":"success","request_id":"cmux-list-options","response":{"models":[{"value":"default","displayName":"Default"},{"value":"host-next-999","displayName":"Host Next 999"}]}}}"#)

        let result = await makeStrategy(probe: probe).models(for: .claude)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(id: "host-next-999", displayName: "Host Next 999"),
            ],
            source: .discovered
        ))
        let commands = await probe.commands
        #expect(commands.count == 1)
        #expect(commands[0].0.contains("claude -p"))
        #expect(commands[0].0.contains("list_models"))
        #expect(commands[0].1 == .seconds(30))
        #expect(await probe.readPaths.isEmpty)
    }

    @Test func codexUsesAgentOwnedCacheAsAuthoritativeCatalog() async {
        let probe = MobileTaskModelStrategyProbe()
        await probe.setFile(
            path: "/Users/tester/.codex/models_cache.json",
            data: Data(#"{"models":[{"slug":"host-next-999","display_name":"Host Next 999","visibility":"list"},{"slug":"hidden-model","display_name":"Hidden","visibility":"hide"}]}"#.utf8)
        )

        let result = await makeStrategy(probe: probe).models(for: .codex)

        #expect(result == MobileTaskModelListResult(
            models: [
                MobileTaskModel(id: "host-next-999", displayName: "Host Next 999"),
            ],
            source: .discovered
        ))
        #expect(await probe.commands.isEmpty)
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
        #expect(claude.source == .fallback)
        #expect(claude.models.isEmpty)
        #expect(openCode.source == .fallback)
        #expect(openCode.models.isEmpty)
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
