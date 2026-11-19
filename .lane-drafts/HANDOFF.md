# Handoff: sidebar nested subagents (claude-app-gaps)

- Checkout: /home/cmux/Projects/checkouts/cmux/lane--sidebar-nested-subagents (made with `git worktree add` from the mirror after `wt new` timed out on a fetch; base cd39a8783640, origin/feat-cmux-next)
- Branch: lane/sidebar-nested-subagents
- Local head: e7d575e64d56 (WIP Swift commit, NOT pushed) on top of 38afb2850017 (Rust, pushed)
- Drafts not yet in the tree: /home/cmux/Projects/scratch-claude-app-gaps/sidebar-nested-subagents-drafts/

## PR 1 (Rust): done, open
- https://github.com/manaflow-ai/cmux/pull/46870, head 38afb2850017f955067c83afbecdb60568ca230f, base feat-cmux-next, label risk:normal.
- What it does: the acpmux summary gains `recentSubagents` (latest 8: id, parent, title, state running/done/failed/stopped) and `subagentsSeen` (total count).
  - Files: new `cmux-tui/crates/acpmux/src/subagents_recent.rs` and `subagents_recent_tests.rs`; edits to subagents.rs (fields `recent`/`recent_revision`, `note_recent` in annotate_live, `adopt_recent` in adopt), hub/views.rs (sets both keys), hub/tap.rs (a revision change also sets `running_changed`, so a `subagents_running` record goes out), hub/list_tee/summary.rs (`EXTRA_KEYS`), and hub/work_below_tests.rs (a new hub test).
  - Bounding: past 8, the oldest finished entry is dropped first. Titles are secret-masked and cut like `subagentNames`. A "running" entry that is not in `running_now(turn_runs)` reads `stopped`.
- Tests: NOT yet run. Local cargo is impossible on this host (2 cores, load 25+). I stopped the fleet run (`cmux-ci test -- bash -c "cd cmux-tui && cargo test -p acpmux --lib subagents"`) on the coordinator's order. Run it first.
- Push gotcha: the pre-push hook took ~26 min here and then the broker had "no time left". After the hook had passed on that exact commit, I sent it with `lane-gh push manaflow-ai/cmux lane/sidebar-nested-subagents --base feat-cmux-next --rev <sha>`. A pr-owner timeout ("busy: retry") also refused one push.
- PR body: the style guard refuses a body that opens with "Leo asked"; open with the problem and the behavior.
- Left for PR 1: CI wait (`glaeda-gh wait pr 46870 --timeout ...`), then `glaeda-gh land manaflow-ai/cmux#46870`.

## PR 2 (Swift, stack on PR 1): in progress, not compiled
Done in the WIP commit:
- Model/SidebarSubagents.swift: `SidebarSubagent` (id, title, state, parent, tab) and `SidebarSubagents` (items, total, running, chat).
- Logic/SidebarSubagentStrip.swift:
  - `SidebarSubagentLook` (rows/stack/both, default both).
  - `SidebarSubagentStrip.make`:
    - Rows mode while the tree is on and the parent is unfolded: at most 5 rows, then "N more".
    - Stack mode otherwise. With the tree off it shows only while some subagent runs.
- SidebarWorkspace.subagents, WorkspaceRowContent.subagents.
- SidebarLayoutMetrics:
  - New fields `subagentLineHeight`/`subagentStackHeight`, set in LayoutMetrics+Tokens `standard`.
  - `height(for:)` adds `subagentsHeight`.
  - Option `subagentLook`.
  - `rowContent` builds the strip and gives a subagent-only parent a treeFold chevron when the tree is on.
- SidebarLayout emit: `tree.fold ?? content.treeFold`.
- SidebarSessionTree.toggle(_:keeping:), so a fold on a subagent-only parent survives pruning. Wiring passes every workspace that has subagent items.
- SidebarModel.openSubagent hook `((WorkspaceID, TabID, SidebarSubagent?) -> Void)?`. `rowOptions` reads `SidebarTunables.subagentLook`.
- Tunables `sidebar.subagents.look` and `sidebar.subagents.fixture`, both registered in `all`.
- Views/SidebarSubagentsView.swift: line views keyed by subagent id (stable, no jumps), "N more" line, stack line, tree line. Presses land on the container through the row's `interactiveSubviews`, and `mouseUp` dispatches to the line under the point.
- WorkspaceRowView:
  - `subagentsView`, `subagentsHeight`.
  - A `headFill` layer, so the selection/hover fill covers only the head when lines hang below.
  - Changes to configure, layout (WorkspaceRowView+Status.swift `layoutSubagents`), prepareForReuse and wiring.
- Strings+Subagents.swift (10 keys).
- AgentChatDetail parses `recentSubagents`/`subagentsSeen` (struct `Subagent`).

Left:
1. Bridge: new CmuxNextBridge/SidebarMapping+Subagents.swift (draft in drafts/bridge.swift; pass `chat:` = the chat tab). Set `row.subagents = Self.subagents(tabs)` in SidebarMapping+Face.swift next to `row.detail`. Check that the face rebuilds when AgentTurnStateStore detail changes.
2. App: add `AgentTabStore.openSubagentFromSidebar` to AgentTabs+Header.swift, the same file as the private `openSubagent`. Add a SidebarBridge wire that sets `model.openSubagent` (revealPinnedTab, then open), called next to `SidebarWorkspacePins.wire(self)` in SidebarBridge.swift. Draft: drafts/app.swift.
3. Localizable.xcstrings: `python3 drafts/strings.py Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Resources/Localizable.xcstrings` (all 21 languages; keeps the file format).
4. Fixture: drafts/SidebarSubagentFixture.swift, applied in CmuxNextAgentLanes SidebarLaneStatus.applying when `subagentFixture` is on, plus a redraw trigger like laneFixture's ObservationStream.
5. Tests: drafts/SidebarSubagentRowsTests.swift goes next to SidebarSessionTreeTests. Also add an AgentChatDetail parse test.
6. Tour: drafts/sidebar-subagents.json goes to scripts/cmux-next/media/tours/. Then `cmux-ci capture <sha> --state tour:sidebar-subagents --pr N`.
7. A parity-mac.md row (phone: missing).
8. `cmux-ci compile-check --ref SHA --app`. Fix compile errors. Unverified risks:
   - `SidebarStyle.textY` takes a ChromeLabel (`SidebarRowView.label` returns one).
   - StatusIndicatorView `.working(progress:nil)`.
   - Overrides that may need `nonisolated` (`cursorUpdate`, `resetCursorRects`).
   - `headFill` inserted before `layer` exists (check that `layer` is non-nil in init).
9. Prepush gate, push (`--base lane/sidebar-nested-subagents`, or feat-cmux-next once #46870 merges), PR with screenshots, then `glaeda-gh land manaflow-ai/cmux#N --after manaflow-ai/cmux#46870`.

Design notes: the lines draw inside the workspace row, like the status block, not as separate rows. That avoids touching the exhaustive row-key, drag and fold switches, and it works in every placement because `rowContent` is the single source. The `sidebar.sessionTree` default is untouched.
