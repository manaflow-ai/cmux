# Run on N agents (+ menu, `/run-on`, ⌘⌥↩): the composer's prompt on 2 to 4 agents, each a sub-session in its own worktree, compared in the chat's runs card; Keep this one closes the others and removes their worktrees

- Section: Agent chat
- Mac sends: acpmux `_acpmux/plan/fanout`, `_acpmux/plan/keep {removeOthers}` (`runOnAgents/`)
- Phone: none
- State: not from a phone
- Notes: It starts several agents in new worktrees with the chat's policy and removes folders on the Mac. acpmux serves the plan build methods to this Mac's person connection only (a remote WebSocket device or a peer is refused), as for goals and the plan approval's builds. A phone path needs a policy first (#13742).
