import Testing
@testable import CmuxFoundation

@Suite("Plugin manifest validation")
struct CmuxPluginManifestTests {
    static let example = """
    [plugin]
    name = "git-tools"
    kind = "extension"
    version = "0.1.0"
    description = "Git helpers"
    platforms = ["macos", "linux"]

    [[actions]]
    id = "open-pr"
    title = "Open Pull Request"
    keywords = ["github"]
    argv = ["./bin/open-pr", "--web"]
    shortcut = "cmd+shift+y"

    [[actions]]
    id = "quiet"
    title = "Quiet"
    argv = ["true"]
    palette = false
    timeout_seconds = 5

    [[events]]
    event = "workspace.created"
    argv = ["./bin/on-workspace"]
    """

    @Test("Parses an extension manifest with actions and events")
    func parsesExtension() throws {
        let manifest = try CmuxPluginManifest.parse(Self.example)
        #expect(manifest.name == "git-tools")
        #expect(manifest.kind == .extension)
        #expect(manifest.version == "0.1.0")
        #expect(manifest.supportsMacOS)
        #expect(manifest.actions == [
            CmuxPluginAction(
                id: "open-pr",
                title: "Open Pull Request",
                keywords: ["github"],
                argv: ["./bin/open-pr", "--web"],
                shortcut: "cmd+shift+y"
            ),
            CmuxPluginAction(id: "quiet", title: "Quiet", argv: ["true"], palette: false, timeoutSeconds: 5),
        ])
        #expect(manifest.events == [
            CmuxPluginEventHook(event: "workspace.created", argv: ["./bin/on-workspace"]),
        ])
    }

    @Test("Still accepts the cmux-tui sidebar manifest shape")
    func parsesSidebarManifest() throws {
        let manifest = try CmuxPluginManifest.parse("""
        [plugin]
        name = "fzf"
        kind = "sidebar"

        [run]
        command = ["target/release/cmux-sidebar-fzf"]

        [build]
        command = ["cargo", "build", "--release"]
        """)
        #expect(manifest.kind == .sidebar)
        #expect(manifest.runCommand == ["target/release/cmux-sidebar-fzf"])
        #expect(manifest.buildCommand == ["cargo", "build", "--release"])
    }

    @Test("Rejects manifests that would be ambiguous or do nothing", arguments: [
        // Unknown keys catch typos.
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[actions]]\nid = \"x\"\ntitle = \"X\"\nargv = [\"true\"]\nargs = [\"true\"]",
        // Names keep plugin.<name>.<action> unambiguous.
        "[plugin]\nname = \"A.b\"\nkind = \"extension\"\n[[events]]\nevent = \"x\"\nargv = [\"true\"]",
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[actions]]\nid = \"x.y\"\ntitle = \"X\"\nargv = [\"true\"]",
        // An extension must contribute something.
        "[plugin]\nname = \"a\"\nkind = \"extension\"",
        // argv must be a non-empty string array.
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[events]]\nevent = \"x\"\nargv = []",
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[events]]\nevent = \"x\"\nargv = \"echo hi\"",
        // Duplicate action ids.
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[actions]]\nid = \"x\"\ntitle = \"X\"\nargv = [\"true\"]\n[[actions]]\nid = \"x\"\ntitle = \"Y\"\nargv = [\"true\"]",
        // Actions belong to extension plugins only.
        "[plugin]\nname = \"a\"\nkind = \"sidebar\"\n[run]\ncommand = [\"x\"]\n[[actions]]\nid = \"x\"\ntitle = \"X\"\nargv = [\"true\"]",
        // Unknown top-level tables are reserved for later plugin features.
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[panes]]\nid = \"x\"",
        "[plugin]\nname = \"a\"\nkind = \"extension\"\n[[events]]\nevent = \"x\"\nargv = [\"true\"]\ntimeout_seconds = 0",
        "[plugin]\nname = \"a\"\nkind = \"extension\"\nplatforms = [\"macos\", \"macos\"]\n[[events]]\nevent = \"x\"\nargv = [\"true\"]",
    ])
    func rejectsInvalid(_ text: String) {
        #expect(throws: CmuxPluginManifestError.self) {
            try CmuxPluginManifest.parse(text)
        }
    }

    @Test("A platforms list without macos parses but reports no macOS support")
    func platformsWithoutMacOS() throws {
        let manifest = try CmuxPluginManifest.parse("""
        [plugin]
        name = "a"
        kind = "extension"
        platforms = ["linux"]
        [[events]]
        event = "x"
        argv = ["true"]
        """)
        #expect(!manifest.supportsMacOS)
    }
}
