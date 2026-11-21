import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Mobile task Codex installation")
struct MobileTaskCodexInstallationTests {
    @Test(arguments: [true, false], ["/bin/bash --noprofile --norc", "/bin/zsh -df"])
    func selectedInstallationSuppliesCatalogAndDefault(liveCatalog: Bool, shellCommand: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shell = directory.appendingPathComponent("login-shell")
        // Only the fixture's binaries and settings are visible to discovery.
        try writeExecutable("""
        #!/bin/sh
        cd "$(/usr/bin/dirname "$0")" || exit 1
        export HOME="$PWD" PATH="$PWD/bin"
        account=$(/bin/cat active)
        export CODEX_HOME="$account"
        export CMUX_CUSTOM_CODEX_PATH="$PWD/bin/pinned ' codex=2"
        exec \(shellCommand) "$@"
        """, to: shell)
        let defaultCatalog = #"{"models":[{"slug":"wrong-installation","visibility":"list"}]}"#
        try writeExecutable("#!/bin/sh\nprintf '%s' '\(defaultCatalog)'", to: bin.appendingPathComponent("codex"))
        try writeExecutable("""
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = debug ] && [ "$2" = models ] || exit 2
        \(liveCatalog ? #"exec /bin/cat "$CODEX_HOME/live.json""# : "exit 1")
        """, to: bin.appendingPathComponent("pinned ' codex=2"))

        let discovery = MobileTaskModelDiscovery.live(homeDirectory: directory, shellPath: shell.path)
        for (account, model) in [("profile one", "profile-one"), (#"profile\two"#, "profile-two")] {
            let profile = directory.appendingPathComponent(account)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let catalog = #"{"models":[{"slug":"\#(model)","visibility":"list"}]}"#
            let filename = liveCatalog ? "live.json" : "models_cache.json"
            try Data(catalog.utf8).write(to: profile.appendingPathComponent(filename))
            try Data("model = \"\(model)\"".utf8).write(to: profile.appendingPathComponent("config.toml"))
            try Data(account.utf8).write(to: directory.appendingPathComponent("active"))

            let result = await discovery.models(for: .codex)
            #expect(result.models.map(\.id) == [model])
            #expect(result.defaultModel?.id == model)
        }

        // Removing the override switches the executable while the account stays the same.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("pinned ' codex=2"))
        let fallback = await discovery.models(for: .codex)
        #expect(fallback.models.map(\.id) == ["wrong-installation"])
        #expect(fallback.defaultModel == nil)
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data((script + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
