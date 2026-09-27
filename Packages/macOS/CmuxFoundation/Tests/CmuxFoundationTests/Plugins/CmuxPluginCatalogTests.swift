import Foundation
import Testing
@testable import CmuxFoundation

@Suite("Plugin install layout, enablement, and invocation")
struct CmuxPluginCatalogTests {
    private let home: URL
    private let paths: CmuxPluginPaths

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = CmuxPluginPaths(homeDirectory: home)
    }

    private func writePlugin(named name: String, at directory: URL, argv: String = "\"./run.sh\"") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        [plugin]
        name = "\(name)"
        kind = "extension"

        [[actions]]
        id = "hello"
        title = "Say Hello"
        argv = [\(argv)]
        """.write(to: directory.appendingPathComponent("cmux-plugin.toml"), atomically: true, encoding: .utf8)
    }

    @Test("A new install is disabled until enabled, and a manifest change disables it again")
    func enablementFollowsFingerprint() throws {
        let directory = paths.installDirectory(for: "demo")
        try writePlugin(named: "demo", at: directory)

        var plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        #expect(plugin.status == .disabled)
        #expect(CmuxPluginCatalog.load(paths: paths).activePlugins.isEmpty)

        try CmuxPluginEnablementStore(fileURL: paths.enablementFile).enable("demo", fingerprint: plugin.fingerprint)
        plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        #expect(plugin.status == .enabled)

        try writePlugin(named: "demo", at: directory, argv: "\"./other.sh\"")
        plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        #expect(plugin.status == .changed)
        #expect(!plugin.isActive)
    }

    @Test("Link, remove, and name mismatches")
    func linkAndRemove() throws {
        let installer = CmuxPluginInstaller(paths: paths)
        let source = home.appendingPathComponent("src/demo", isDirectory: true)
        try writePlugin(named: "demo", at: source)

        let linked = try installer.link(source, replacing: false)
        #expect(linked.name == "demo")
        let plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        #expect(plugin.isLinked)
        #expect(plugin.directory.path == source.resolvingSymlinksInPath().path)
        #expect(throws: CmuxPluginManifestError.self) { try installer.link(source, replacing: false) }

        try installer.remove("demo")
        #expect(CmuxPluginCatalog.load(paths: paths).plugins.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("cmux-plugin.toml").path))

        try writePlugin(named: "other", at: paths.installDirectory(for: "demo"))
        let catalog = CmuxPluginCatalog.load(paths: paths)
        #expect(catalog.plugins.isEmpty)
        #expect(catalog.problems.map(\.name) == ["demo"])
    }

    @Test("Staging directories are hidden from the catalog and commit refuses to overwrite")
    func stagingAndCommit() throws {
        let installer = CmuxPluginInstaller(paths: paths)
        let staging = try installer.makeStagingDirectory()
        let checkout = staging.appendingPathComponent("checkout", isDirectory: true)
        try writePlugin(named: "demo", at: checkout)
        #expect(CmuxPluginCatalog.load(paths: paths).plugins.isEmpty)

        let (manifest, _) = try installer.inspect(checkout)
        _ = try installer.commit(checkout, name: manifest.name, replacing: false)
        #expect(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo") != nil)

        let second = try installer.makeStagingDirectory().appendingPathComponent("checkout", isDirectory: true)
        try writePlugin(named: "demo", at: second)
        #expect(throws: CmuxPluginManifestError.self) {
            try installer.commit(second, name: "demo", replacing: false)
        }
        _ = try installer.commit(second, name: "demo", replacing: true)
    }

    @Test("Invocation resolves relative argv, quotes arguments, and exports context")
    func invocationScript() throws {
        let directory = paths.installDirectory(for: "demo")
        try writePlugin(named: "demo", at: directory)
        let plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))
        let invocation = CmuxPluginInvocation(
            plugin: plugin,
            argv: ["./bin/run", "it's $HOME"],
            context: CmuxPluginInvocationContext(
                socketPath: "/tmp/cmux.sock",
                cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux",
                workspaceID: "W1",
                surfaceID: "S1",
                actionID: "plugin.demo.hello"
            ),
            paths: paths
        )
        let runPath = plugin.directory.appendingPathComponent("bin/run").path
        #expect(invocation.resolvedArgv == [runPath, "it's $HOME"])
        let environment = invocation.environment
        #expect(environment["CMUX_PLUGIN_ID"] == "demo")
        #expect(environment["CMUX_PLUGIN_DIR"] == plugin.directory.path)
        #expect(environment["CMUX_PLUGIN_STATE_DIR"] == paths.stateDirectory(for: "demo").path)
        #expect(environment["CMUX_SOCKET_PATH"] == "/tmp/cmux.sock")
        #expect(environment["CMUX_WORKSPACE_ID"] == "W1")
        #expect(environment["CMUX_SURFACE_ID"] == "S1")
        #expect(environment["CMUX_PLUGIN_ACTION_ID"] == "plugin.demo.hello")
        #expect(environment["CMUX_PLUGIN_CONTEXT_JSON"]?.contains("\"workspace_id\":\"W1\"") == true)
        #expect(invocation.shellScript.hasSuffix("exec '\(runPath)' 'it'\\''s $HOME'"))
        #expect(invocation.shellScript.contains("export PATH='/Applications/cmux.app/Contents/Resources/bin':\"$PATH\""))

        let bare = CmuxPluginInvocation(plugin: plugin, argv: ["python3", "x.py"], context: .init(), paths: paths)
        #expect(bare.resolvedArgv == ["python3", "x.py"])
    }

    @Test("The generated script runs argv in the plugin directory with the exported state directory")
    func scriptRuns() throws {
        let directory = paths.installDirectory(for: "demo")
        try writePlugin(named: "demo", at: directory)
        let script = directory.appendingPathComponent("run.sh")
        try """
        #!/bin/sh
        printf '%s|%s|%s' "$CMUX_PLUGIN_ID" "$1" "$PWD" > "$CMUX_PLUGIN_STATE_DIR/out"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let plugin = try #require(CmuxPluginCatalog.load(paths: paths).plugin(named: "demo"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            CmuxPluginInvocation(plugin: plugin, argv: ["./run.sh", "a 'b' $c"], context: .init(), paths: paths).shellScript,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let output = try String(
            contentsOf: paths.stateDirectory(for: "demo").appendingPathComponent("out"),
            encoding: .utf8
        )
        #expect(output == "demo|a 'b' $c|\(plugin.directory.path)")
    }

    @Test("Source shorthand expands to GitHub and URLs with secrets are refused")
    func sources() throws {
        #expect(try CmuxPluginSource.parse("owner/repo") == CmuxPluginSource(cloneURL: "https://github.com/owner/repo.git"))
        #expect(try CmuxPluginSource.parse("owner/repo/plugins/demo") == CmuxPluginSource(
            cloneURL: "https://github.com/owner/repo.git",
            subdirectory: "plugins/demo"
        ))
        #expect(try CmuxPluginSource.parse("git@github.com:owner/repo.git").cloneURL == "git@github.com:owner/repo.git")
        #expect(try CmuxPluginSource.parse("https://example.com/r.git", subdirectory: "p").subdirectory == "p")
        for bad in ["https://user:token@example.com/r.git", "https://example.com/r.git?token=x", "owner", "owner/../x", "--upload-pack=x"] {
            #expect(throws: CmuxPluginManifestError.self, "\(bad)") { try CmuxPluginSource.parse(bad) }
        }
        #expect(throws: CmuxPluginManifestError.self) { try CmuxPluginSource.parse("owner/repo", subdirectory: "../x") }
    }
}
