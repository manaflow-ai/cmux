import Foundation

extension CMUXCLI {
    func hooksUsage() -> String {
        String(localized: "cli.hooks.usage", defaultValue: """
        Usage: cmux hooks setup [agent] [--agent <name>] [--yes|-y]
               cmux hooks uninstall [agent] [--agent <name>] [--yes|-y]
               cmux hooks <agent> install [--yes|-y] (opencode supports --project)
               cmux hooks <agent> uninstall [--yes|-y] (opencode supports --project)
               cmux hooks <agent> <event> [flags]
               cmux hooks feed --source <agent> [--event <event>]

        Manage and run cmux agent hooks without adding one top-level command per
        agent. Claude Code hooks are injected automatically by the cmux Claude wrapper.

        Agents:
          codex, grok, opencode, pi, omp, campfire, amp, cursor, gemini, kiro, antigravity (alias: agy), rovodev (alias: rovo), hermes-agent, copilot, codebuddy, factory, qoder, kimi

        Hook targets:
          setup              Install hooks for all supported agents on PATH
          uninstall          Remove hooks for all supported agents
          <agent> install    Install one agent integration
          <agent> uninstall  Remove one agent integration
          <agent> <event>    Internal hook entrypoint used by generated configs
          feed               Internal Feed decision bridge

        Generated files:
          ~/.config/opencode/plugins/cmux-session.js
          ~/.config/opencode/plugins/cmux-feed.js
          ~/.pi/agent/extensions/cmux-session.ts
          ~/.omp/agent/extensions/cmux-omp-session.ts
          ~/.campfire/agent/extensions/cmux-campfire-session.ts
          ~/.config/amp/plugins/cmux-session.ts
          ~/.kiro/agents/cmux.json
          ~/.kimi/config.toml
          See docs/agent-hooks.md for the full integration matrix.

        Examples:
          cmux hooks setup
          cmux hooks setup --agent codex
          cmux hooks setup rovo
          cmux hooks setup omp
          cmux hooks uninstall rovo
          cmux hooks codex install
          cmux hooks opencode install --project
          cmux hooks uninstall
        """)
    }
}
