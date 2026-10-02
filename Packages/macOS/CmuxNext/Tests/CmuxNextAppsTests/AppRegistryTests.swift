import Foundation
import Testing
@testable import CmuxNextApps

/// The prototype registry: bundled + local apps, the install record.
struct AppRegistryTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "cmux-apps-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeLocal(_ root: URL, name: String, id: String) throws {
        let dir = root.appending(path: "local/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = #"{"manifestVersion":1,"id":"\#(id)","name":"N","version":"0.1.0","description":"d","engines":{"cmux":"^1.0"}}"#
        try Data(manifest.utf8).write(to: dir.appending(path: "cmux-app.json"))
    }

    @Test func bundledSamplesAndLocalAppsAreInstalledByDefault() async throws {
        let root = try scratch()
        try writeLocal(root, name: "mine", id: "local/mine")
        try writeLocal(root, name: "impostor", id: "cmux/impostor")
        let registry = AppRegistry(directory: root)
        await registry.load()
        #expect(registry.apps.map(\.id) == ["cmux/agent-status", "cmux/github-prs", "cmux/running-agents", "local/mine"])
        #expect(registry.apps.allSatisfy { $0.isActive })
        #expect(registry.app("local/mine")?.bundle.source == .local)
        #expect(registry.problems.count == 1)
        #expect(registry.problems.first?.message.contains("local/ publisher") == true)
    }

    @Test func installRemoveAndEnableArePersistedPerTagDirectory() async throws {
        let root = try scratch()
        let registry = AppRegistry(directory: root)
        await registry.load()
        try await registry.remove("cmux/github-prs")
        try await registry.setEnabled("cmux/running-agents", false)
        #expect(registry.app("cmux/github-prs")?.isInstalled == false)
        #expect(registry.active.map(\.id) == ["cmux/agent-status"])

        let reloaded = AppRegistry(directory: root)
        await reloaded.load()
        #expect(reloaded.app("cmux/github-prs")?.isInstalled == false)
        #expect(reloaded.app("cmux/running-agents")?.isEnabled == false)
        try await reloaded.install("cmux/github-prs")
        #expect(reloaded.app("cmux/github-prs")?.isActive == true)
    }

    @Test func appsDirectoryFollowsTheTag() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(AppRegistryFile.appsDirectory(tag: "apps1", home: home).path == "/Users/x/Library/Application Support/cmux/apps1/apps")
        #expect(AppRegistryFile.appsDirectory(tag: nil, home: home).path == "/Users/x/Library/Application Support/cmux/default/apps")
    }
}
