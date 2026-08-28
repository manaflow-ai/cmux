import Testing
@testable import CmuxFoundation

/// Exercises the complete Codex config install/uninstall transform without an
/// app host or a user-owned `~/.codex` directory.
@Suite("Codex config editor")
struct CmuxCodexConfigEditorTests {
    private let editor = CmuxCodexConfigEditor()

    private static let featureBegin =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin"
    private static let featureEnd =
        "# cmux-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df end"
    private static let trustBegin =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin"
    private static let trustEnd =
        "# cmux-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"

    private static let trustEntries = [
        CmuxCodexConfigEditor.HookTrustEntry(
            key: "/tmp/cmux-hooks:pre_tool_use:0:0",
            trustedHash: "sha256:test-hook"
        )
    ]

    @Test("Reinstalling a CRLF config keeps one complete trust block")
    func reinstallDoesNotDuplicateTrustBlockOrLeaveOrphanMarker() {
        let initial = "model = \"gpt-5\"\napproval_policy = \"on-request\"\n"
        let firstInstall = editor.installingHooks(
            in: initial,
            trustEntries: Self.trustEntries
        )
        let crlfConfig = firstInstall.content.replacingOccurrences(of: "\n", with: "\r\n")

        let reinstalled = editor.installingHooks(
            in: crlfConfig,
            trustEntries: Self.trustEntries
        )

        #expect(Self.occurrences(of: Self.featureBegin, in: reinstalled.content) == 1)
        #expect(Self.occurrences(of: Self.featureEnd, in: reinstalled.content) == 1)
        #expect(Self.occurrences(of: Self.trustBegin, in: reinstalled.content) == 1)
        #expect(Self.occurrences(of: Self.trustEnd, in: reinstalled.content) == 1)
        #expect(reinstalled.content.contains(Self.trustBegin + "\r\n"))
        #expect(reinstalled.content.contains(Self.trustEnd + "\r\n"))
        #expect(reinstalled.content == crlfConfig)
    }

    @Test("Uninstall removes the hooks feature setting and its markers")
    func uninstallRemovesFeaturesHooksSetting() {
        let installed = editor.installingHooks(
            in: "model = \"gpt-5\"\n",
            trustEntries: Self.trustEntries
        )

        let uninstalled = editor.uninstallingHooks(
            from: installed.content,
            removingHookTrustEntries: Self.trustEntries
        )

        #expect(!uninstalled.contains("hooks = true"))
        #expect(!uninstalled.contains(Self.featureBegin))
        #expect(!uninstalled.contains(Self.featureEnd))
        #expect(!uninstalled.contains(Self.trustBegin))
        #expect(!uninstalled.contains(Self.trustEnd))
    }

    @Test("A CRLF install followed by uninstall restores bytes exactly")
    func crlfInstallUninstallRoundTripIsByteForByte() {
        let original = "model = \"gpt-5\"\r\napproval_policy = \"on-request\"\r\n"
        let installed = editor.installingHooks(
            in: original,
            trustEntries: Self.trustEntries
        )

        let restored = editor.uninstallingHooks(
            from: installed.content,
            removingHookTrustEntries: Self.trustEntries
        )

        #expect(restored == original)
    }

    @Test("An install with no trust entries still enables the feature")
    func installWithoutTrustEntriesReportsNoTrust() {
        let result = editor.installingHooks(in: "model = \"gpt-5\"\n", trustEntries: [])

        #expect(!result.installedTrust)
        #expect(result.content.contains("hooks = true"))
        #expect(result.content.contains(Self.featureBegin))
    }

    @Test("Hook state override sorts and escapes trust keys")
    func hookStateOverrideSortsAndEscapesTrustKeys() {
        let entries = [
            CmuxCodexConfigEditor.HookTrustEntry(
                key: "/tmp/z\"hook:post_tool_use:0:0",
                trustedHash: "sha256:z"
            ),
            CmuxCodexConfigEditor.HookTrustEntry(
                key: "/tmp/a-hook:pre_tool_use:0:0",
                trustedHash: "sha256:a"
            ),
        ]

        let override = editor.hookStateOverrideDisabling(entries)

        #expect(
            override ==
                #"hooks.state={"/tmp/a-hook:pre_tool_use:0:0"={enabled=false},"/tmp/z\"hook:post_tool_use:0:0"={enabled=false}}"#
        )
    }

    @Test("Hook state override is absent without trust entries")
    func hookStateOverrideIsAbsentWithoutTrustEntries() {
        #expect(editor.hookStateOverrideDisabling([]) == nil)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
