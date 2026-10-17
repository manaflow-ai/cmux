import CMUXAgentLaunch
import Foundation
import Testing

@Suite("HermesAgentHookConfig")
struct HermesAgentHookConfigTests {
    @Test("Installs hooks into empty config")
    func installsHooksIntoEmptyConfig() {
        let events = [
            HermesAgentHookConfig.Event(name: "on_session_start", command: "sh -c 'cmux hooks hermes-agent session-start'"),
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: "")

        #expect(installed.contains("# cmux hooks hermes-agent begin\nhooks:\n  on_session_start:"))
        #expect(installed.contains("    - command: \"sh -c 'cmux hooks hermes-agent session-start'\""))
        #expect(installed.contains("      timeout: 120"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == "")
    }

    @Test("Coalesces multiple cmux hooks for the same missing Hermes event")
    func coalescesMultipleHooksForSameMissingEvent() {
        let events = [
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks hermes-agent notification'"),
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'", timeout: 120),
            HermesAgentHookConfig.Event(name: "post_llm_call", command: "sh -c 'cmux hooks hermes-agent agent-response'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: "")

        #expect(installed.components(separatedBy: "\n  pre_approval_request:").count == 2)
        #expect(
            installed.contains("""
              pre_approval_request:
                - command: "sh -c 'cmux hooks hermes-agent notification'"
                  timeout: 5
                - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'"
                  timeout: 120
            """)
        )
        #expect(installed.contains("  post_llm_call:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == "")
    }

    @Test("Coalesces multiple cmux hooks for the same existing Hermes event")
    func coalescesMultipleHooksForSameExistingEvent() {
        let existing = """
        hooks:
          pre_approval_request:
            - command: "echo user"
              timeout: 10

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks hermes-agent notification'"),
            HermesAgentHookConfig.Event(name: "pre_approval_request", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'", timeout: 120),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.components(separatedBy: "\n  pre_approval_request:").count == 2)
        #expect(
            installed.contains("""
              pre_approval_request:
                # cmux hooks hermes-agent begin
                - command: "sh -c 'cmux hooks hermes-agent notification'"
                  timeout: 5
                - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_approval_request'"
                  timeout: 120
                # cmux hooks hermes-agent end
                - command: "echo user"
                  timeout: 10
            """)
        )
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Preserves existing hook events without duplicating keys")
    func preservesExistingHookEventsWithoutDuplicatingKeys() {
        let existing = """
        model: anthropic/claude-sonnet-4.6
        hooks:
          pre_tool_call:
            - command: "echo user"
              timeout: 10
          post_llm_call:
            - command: "echo done"

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
            HermesAgentHookConfig.Event(name: "on_session_end", command: "sh -c 'cmux hooks hermes-agent stop'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.components(separatedBy: "\n  pre_tool_call:").count == 2)
        #expect(installed.contains("  pre_tool_call:\n    # cmux hooks hermes-agent begin\n    - command: \"sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'\""))
        #expect(installed.contains("    - command: \"echo user\""))
        #expect(installed.contains("  on_session_end:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Installs into multiple existing hook events without shifting later indexes")
    func installsIntoMultipleExistingEventsWithoutShiftingLaterIndexes() {
        let existing = """
        hooks:
          pre_tool_call:
            - command: "echo pre"
          post_tool_call:
            - command: "echo post"

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("  pre_tool_call:\n    # cmux hooks hermes-agent begin"))
        #expect(installed.contains("  post_tool_call:\n    # cmux hooks hermes-agent begin"))
        #expect(installed.contains("    - command: \"echo pre\""))
        #expect(installed.contains("    - command: \"echo post\""))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Installs into inline-empty hook events")
    func installsIntoInlineEmptyHookEvents() {
        let existing = """
        hooks:
          pre_tool_call: []
          post_tool_call: {} # intentionally empty

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("  pre_tool_call:\n    # cmux hooks hermes-agent begin"))
        #expect(installed.contains("  post_tool_call:\n    # cmux hooks hermes-agent begin"))
        #expect(!installed.contains("pre_tool_call: []\n    # cmux hooks hermes-agent begin"))
        #expect(!installed.contains("post_tool_call: {} # intentionally empty\n    # cmux hooks hermes-agent begin"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    @Test("Uninstalls inline-empty hooks root")
    func uninstallsInlineEmptyHooksRoot() {
        let existing = """
        model: anthropic/claude-sonnet-4.6
        hooks: [] # intentionally empty

        """
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
            HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'"),
        ]

        let installed = HermesAgentHookConfig.installing(events: events, in: existing)

        #expect(installed.contains("hooks:\n  # cmux hooks hermes-agent begin restore-line-base64:"))
        #expect(installed.contains("  pre_tool_call:"))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
    }

    private let lifecycleEvents = [
        HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
        HermesAgentHookConfig.Event(name: "post_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event post_tool_call'", timeout: 120),
    ]

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// With no `hooks:` key cmux writes the key itself, inside its markers. A
    /// tool that later adds an entry under that key is still inside them.
    @Test("A refresh keeps entries another tool added under the hooks key cmux created")
    func refreshKeepsEntriesAddedUnderCreatedHooksKey() {
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: "model: m\n")
        let shared = installed
            .replacingOccurrences(
                of: "  pre_tool_call:\n",
                with: "  pre_tool_call:\n    - command: \"my_tool pre\"\n      timeout: 3\n"
            )
            .replacingOccurrences(
                of: "# cmux hooks hermes-agent end",
                with: "    - matcher: \"terminal\"\n      command: 'my_tool post'\n# cmux hooks hermes-agent end"
            )
        #expect(occurrences(of: "my_tool", in: shared) == 2)

        let refreshed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: shared)

        #expect(occurrences(of: "my_tool", in: refreshed) == 2)
        #expect(refreshed.contains("    - command: \"my_tool pre\"\n      timeout: 3\n"))
        #expect(refreshed.contains("    - matcher: \"terminal\"\n      command: 'my_tool post'\n"))
        #expect(occurrences(of: "--event pre_tool_call", in: refreshed) == 1)
        #expect(occurrences(of: "--event post_tool_call", in: refreshed) == 1)
        #expect(occurrences(of: "\nhooks:", in: refreshed) == 1)
        #expect(occurrences(of: "\n  pre_tool_call:", in: refreshed) == 1)
        #expect(occurrences(of: "\n  post_tool_call:", in: refreshed) == 1)
        #expect(HermesAgentHookConfig.installing(events: lifecycleEvents, in: refreshed) == refreshed)
        #expect(HermesAgentHookConfig.uninstalling(from: refreshed) == """
        model: m

        hooks:
          pre_tool_call:
            - command: "my_tool pre"
              timeout: 3
          post_tool_call:
            - matcher: "terminal"
              command: 'my_tool post'

        """)
    }

    /// With `hooks:` present but no event key, cmux writes the event keys
    /// inside its markers.
    @Test("A refresh keeps entries another tool added under an event key cmux created")
    func refreshKeepsEntriesAddedUnderCreatedEventKey() {
        let existing = """
        hooks:
          on_session_start:
            - command: "echo start"

        """
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: existing)
        let shared = installed.replacingOccurrences(
            of: "  # cmux hooks hermes-agent end",
            with: "    - command: my_tool post\n  on_custom:\n    - command: my_tool custom\n  # cmux hooks hermes-agent end"
        )
        #expect(occurrences(of: "my_tool", in: shared) == 2)

        let refreshed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: shared)

        #expect(occurrences(of: "my_tool", in: refreshed) == 2)
        #expect(occurrences(of: "--event pre_tool_call", in: refreshed) == 1)
        #expect(occurrences(of: "--event post_tool_call", in: refreshed) == 1)
        #expect(occurrences(of: "\n  post_tool_call:", in: refreshed) == 1)
        #expect(HermesAgentHookConfig.installing(events: lifecycleEvents, in: refreshed) == refreshed)
        #expect(HermesAgentHookConfig.uninstalling(from: refreshed) == """
        hooks:
          post_tool_call:
            - command: my_tool post
          on_custom:
            - command: my_tool custom
          on_session_start:
            - command: "echo start"

        """)
    }

    @Test("Uninstall keeps entries another tool added inside cmux's markers")
    func uninstallKeepsEntriesAddedInsideMarkers() {
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: "")
        let shared = installed.replacingOccurrences(
            of: "  post_tool_call:\n",
            with: "  post_tool_call:\n    - command: |\n        my_tool post\n      timeout: 9\n"
        )

        #expect(HermesAgentHookConfig.uninstalling(from: shared) == """
        hooks:
          post_tool_call:
            - command: |
                my_tool post
              timeout: 9

        """)
    }

    @Test("A refresh keeps an entry another tool added between cmux's entries under an existing key")
    func refreshKeepsEntryAddedBetweenCmuxEntries() {
        let existing = """
        hooks:
          pre_tool_call:
            - command: "echo user"
          post_tool_call:
            - command: "echo post"

        """
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: existing)
        let shared = installed.replacingOccurrences(
            of: "    # cmux hooks hermes-agent end\n    - command: \"echo user\"",
            with: "    - command: \"my_tool pre\"\n    # cmux hooks hermes-agent end\n    - command: \"echo user\""
        )
        #expect(occurrences(of: "my_tool", in: shared) == 1)

        let refreshed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: shared)

        #expect(occurrences(of: "my_tool", in: refreshed) == 1)
        #expect(occurrences(of: "--event pre_tool_call", in: refreshed) == 1)
        #expect(HermesAgentHookConfig.uninstalling(from: refreshed) == """
        hooks:
          pre_tool_call:
            - command: "my_tool pre"
            - command: "echo user"
          post_tool_call:
            - command: "echo post"

        """)
    }

    /// cmux's lifecycle hooks run `"$cmux_cli" hooks enqueue hermes-agent ...`
    /// inside a longer script. A cmux entry kept as another tool's would be
    /// written again on every refresh and left behind on uninstall.
    @Test("cmux's own entries in any form are replaced, not kept beside the new ones")
    func cmuxEntriesInAnyFormAreReplaced() {
        func events(timeoutSeconds: Int) -> [HermesAgentHookConfig.Event] {
            [
                HermesAgentHookConfig.Event(
                    name: "on_session_start",
                    command: "sh -c 'cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-cmux}\"; CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=\(timeoutSeconds) \"$cmux_cli\" hooks enqueue hermes-agent session-start || true'"
                ),
                HermesAgentHookConfig.Event(
                    name: "pre_tool_call",
                    command: "sh -c '\"$cmux_cli\" hooks feed --source hermes-agent --event pre_tool_call'",
                    timeout: 120
                ),
            ]
        }
        let existing = """
        model: m
        hooks:
          pre_tool_call:
            - command: other

        """

        let installed = HermesAgentHookConfig.installing(events: events(timeoutSeconds: 2), in: existing)
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == existing)
        #expect(HermesAgentHookConfig.uninstalling(
            from: HermesAgentHookConfig.installing(events: events(timeoutSeconds: 2), in: "")
        ) == "")

        let upgraded = HermesAgentHookConfig.installing(events: events(timeoutSeconds: 3), in: installed)
        #expect(occurrences(of: "hooks enqueue hermes-agent session-start", in: upgraded) == 1)
        #expect(occurrences(of: "TIMEOUT_SEC=2", in: upgraded) == 0)
        #expect(HermesAgentHookConfig.uninstalling(from: upgraded) == existing)

        // A comment a person left inside a cmux entry goes with the entry.
        let annotated = HermesAgentHookConfig.installing(events: events(timeoutSeconds: 2), in: "")
            .replacingOccurrences(of: "      timeout: 120", with: "      # slow on first run\n\n      timeout: 120")
        #expect(HermesAgentHookConfig.uninstalling(from: annotated) == "")

        // So does a comment after a key cmux wrote.
        let annotatedKey = HermesAgentHookConfig.installing(events: events(timeoutSeconds: 2), in: "")
            .replacingOccurrences(of: "  on_session_start:", with: "  on_session_start: # note: mine")
        #expect(HermesAgentHookConfig.uninstalling(from: annotatedKey) == "")
    }

    @Test("A kept entry is kept whole, whatever its lines look like")
    func keptEntryIsKeptWhole() {
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: "")
        let entry = """
            - matcher:
              command: |
                if true; then
                  echo hi:
                fi
                echo done:
              timeout: 9

        """
        let shared = installed.replacingOccurrences(of: "  pre_tool_call:\n", with: "  pre_tool_call:\n" + entry)

        let refreshed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: shared)

        #expect(refreshed.contains(entry))
        #expect(HermesAgentHookConfig.uninstalling(from: refreshed) == "hooks:\n  pre_tool_call:\n" + entry)
    }

    /// PyYAML writes a list at the same indent as its key, and a tool may
    /// indent the children of `hooks:` by four spaces.
    @Test("Installs beside existing entries at the indent they already use")
    func installsAtTheIndentExistingEntriesUse() {
        let unindentedList = """
        hooks:
          pre_tool_call:
          - command: my_tool pre
            timeout: 3
          post_tool_call:
          - command: my_tool post

        """
        let installed = HermesAgentHookConfig.installing(events: lifecycleEvents, in: unindentedList)
        #expect(installed.contains("""
          pre_tool_call:
          # cmux hooks hermes-agent begin
          - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"
            timeout: 120
          # cmux hooks hermes-agent end
          - command: my_tool pre
            timeout: 3
        """))
        #expect(HermesAgentHookConfig.uninstalling(from: installed) == unindentedList)

        let fourSpaces = """
        hooks:
            on_session_start:
                - command: my_tool start

        """
        let installedFourSpaces = HermesAgentHookConfig.installing(events: lifecycleEvents, in: fourSpaces)
        #expect(installedFourSpaces.contains("""
        hooks:
            # cmux hooks hermes-agent begin
            pre_tool_call:
              - command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"
        """))
        #expect(HermesAgentHookConfig.uninstalling(from: installedFourSpaces) == fourSpaces)
    }

    @Test("Allowlist install and uninstall only touches cmux commands")
    func allowlistInstallAndUninstallOnlyTouchesCmuxCommands() throws {
        let existing = """
        {
          "approvals": [
            {
              "command": "echo user",
              "event": "pre_tool_call"
            }
          ]
        }
        """.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'", timeout: 120),
        ]

        let installed = try HermesAgentHookAllowlist.installing(
            events: events,
            in: existing,
            approvedAt: Date(timeIntervalSince1970: 0)
        )
        let installedObject = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        let approvals = try #require(installedObject["approvals"] as? [[String: Any]])
        #expect(approvals.count == 2)

        let uninstalled = try HermesAgentHookAllowlist.uninstalling(events: events, from: installed)
        let uninstalledObject = try #require(JSONSerialization.jsonObject(with: uninstalled) as? [String: Any])
        let remaining = try #require(uninstalledObject["approvals"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect(remaining.first?["command"] as? String == "echo user")
    }

    @Test("Allowlist install preserves non-conforming approvals")
    func allowlistInstallPreservesNonConformingApprovals() throws {
        let existing = """
        {
          "approvals": [
            {
              "event": "pre_tool_call",
              "command": 12,
              "scope": "third-party"
            }
          ]
        }
        """.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
        ]

        let installed = try HermesAgentHookAllowlist.installing(events: events, in: existing)
        let installedObject = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        let approvals = try #require(installedObject["approvals"] as? [[String: Any]])

        #expect(approvals.count == 2)
        #expect(approvals.contains { $0["scope"] as? String == "third-party" })
        #expect(approvals.contains { $0["command"] as? String == events[0].command })
    }

    @Test("Allowlist ownership preserves embedded text and removes legacy cmux invocations")
    func allowlistOwnershipRequiresCmuxInvocation() throws {
        let userMarker = "echo cmux-hermes-agent-hook-v2"
        let userMarkerSuffix = "echo cmux-hermes-agent-hook-v2-user"
        let userLifecycle = "printf '%s' 'hooks hermes-agent prompt-submit'"
        let pinned = "sh -c ': cmux-hermes-agent-hook-v2; cmux hooks hermes-agent session-start'"
        let legacyLifecycle = #"sh -c 'cmux_cli=cmux; "$cmux_cli" hooks hermes-agent prompt-submit'"#
        let legacyFeed = "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"
        let commands = [
            userMarker,
            userMarkerSuffix,
            userLifecycle,
            pinned,
            legacyLifecycle,
            legacyFeed,
        ]
        let approvals: [[String: String]] = commands.enumerated().map {
            ["event": "event-\($0.offset)", "command": $0.element]
        }
        let existing = try JSONSerialization.data(
            withJSONObject: ["approvals": approvals],
            options: [.prettyPrinted, .sortedKeys]
        )
        let noEvents: [HermesAgentHookConfig.Event] = []

        let uninstalled = try HermesAgentHookAllowlist.uninstalling(
            events: noEvents,
            from: existing
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: uninstalled) as? [String: Any]
        )
        let remaining = try #require(object["approvals"] as? [[String: Any]])
        let remainingCommands = Set(remaining.compactMap { $0["command"] as? String })

        #expect(remainingCommands == Set([userMarker, userMarkerSuffix, userLifecycle]))
    }

    @Test("Allowlist install rejects non-object JSON roots")
    func allowlistInstallRejectsNonObjectJSONRoots() throws {
        let existing = #"[]"#.data(using: .utf8)
        let events = [
            HermesAgentHookConfig.Event(name: "pre_tool_call", command: "sh -c 'cmux hooks feed --source hermes-agent --event pre_tool_call'"),
        ]

        do {
            _ = try HermesAgentHookAllowlist.installing(events: events, in: existing)
            Issue.record("expected non-object allowlist JSON to throw")
        } catch {}
    }
}
