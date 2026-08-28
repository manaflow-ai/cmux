# Screen-detection agent source (spec for implementation; delete before PR-ready, fold content into the PR body)

Goal: TUI-parsed agent lifecycle states become cmux-tui JOURNAL events, exactly
like hook events, so the journal-derived agent roster (crates/cmux-tui-core/src/
journal_reducers.rs, PR https://github.com/manaflow-ai/cmux/pull/11002) covers
all 21 herdr-supported agents including ones with no hooks (codex today:
https://github.com/manaflow-ai/cmux/issues/11040). Base branch here already has
the reducer + agent adapter ids.

## Architecture (decided; deviate only with a stated reason)

1. Manifest engine (new module crates/cmux-tui-core/src/screen_detect/):
   port herdr's manifest semantics from /tmp/herdr/src/detect/manifest.rs
   (Apache-2.0; keep a "ported from herdr, modified by manaflow" header):
   TOML rules with: id, state (working|blocked|idle|unknown), priority (higher
   wins), region (osc_title | bottom_non_empty_lines(N) |
   last_non_empty_above_prompt_box | ...), regex / line_regex / contains,
   any / not clauses, visible_working/visible_blocker/visible_idle,
   skip_state_update, aliases, min_engine_version. Manifests load from the
   vendored dir at cmux-tui/vendor/herdr-manifests (compile-time include_dir or
   build-script embed; no network, never call herdr's update endpoint).
2. Detector (daemon-side, per PTY): on output quiescence (debounce ~300ms after
   last output, plus OSC title changes), take the terminal tail (viewport text
   exists server-side; herdr regions need bottom N non-empty lines + the OSC
   title) and evaluate the manifest for the agent identified by the FOREGROUND
   PROCESS NAME of the pane (match manifest id/aliases; no match = not an
   agent = no events). Emit on STATE TRANSITIONS only (edge-triggered, never
   per-scan): append a journal event via Mux::append_journal_ingress with
   producer cmux_agent, the agent-hook payload shape (format cmux.agent-hook.v1,
   adapter {"id":"<manifest id>","version":1}, native_event "ScreenDetect",
   normalized {"state": "..."} ), kind chosen the same way the socket echo
   works: the fold must read the explicit state. EXTEND the fold: a payload
   with native_event "ScreenDetect" carries normalized.state like the socket
   echo but source "detected" (AgentSource::Detected finally earns its name).
   agent field = adapter id.
3. Arbitration IN THE FOLD (journal_reducers.rs): hook > screen > socket per
   terminal. Concretely: a screen event may not overwrite an entry whose source
   is hook and whose updated_at is fresher than STALE_HOOK_MS (suggest 30s);
   a hook event always wins; socket loses to both (existing rule). State the
   chosen staleness rule in the PR.
4. Exit semantics: agent process gone (foreground process no longer matches)
   AND entry source is detected -> emit session-ended-equivalent (roster
   removal). Terminal close already retires entries.
5. Ordering (SEPARATE COMMIT, applies to the dogfood branch rendering too):
   agents views sort by (attention desc, updated_at desc) where attention is
   blocked=3, working=2, idle=1 (herdr does blocked=4 > idle-unseen=3 >
   working=2 > idle-seen=1; our seen-bit needs frontend focus history and is
   explicitly DEFERRED - note it in the PR as the follow-up, do not fake it).
   Change the sort key in the all-scope arm of sidebar_projection.rs on the
   dogfood branch feat-tui-sbsplit-dogfood and in this branch's copy; tests.

## Workflow constraints (hard rules)
- NEVER run cargo/rustc/zig on this Mac. Iterate on a Blacksmith testbox:
  read ~/.claude/projects/-Users-lawrence-fun-cmuxterm-hq/memory/blacksmith-testbox-sync-pitfalls.md
  first (fingerprint wedge, ghostty clobber, fetch-branch repair). Warm with
  scripts/blacksmith-bounded-command.sh 300 blacksmith testbox warmup
  .github/workflows/cmux-tui-testbox-warmup.yml --ref main --job cmux-tui-rust,
  approve the pending deployment via gh api, iterate with
  `blacksmith testbox run` after pushing + remote `git fetch origin <branch>
  --depth 1; git checkout FETCH_HEAD -- cmux-tui/crates`. Stop the box AND
  gh run cancel the warmup when done.
- Gate: ./scripts/verify-cmux-tui-hosted.sh --filter screen_detect (dispatch;
  if the wrapper times out locally, poll the run with gh api until completed).
- cargo fmt: run on the box, bring the diff back as a patch, apply locally.
- Commits: red tests first where a contract is pinned (manifest semantics,
  arbitration, exit); engine can land as its own commit. Push only this branch.
- Demo: rebuild feat-tui-sbsplit-dogfood as merge(this branch, 984a8ecc8d) +
  the ordering commit; hosted focused run; download BOTH binaries from the
  cmux-tui-aarch64-apple-darwin artifact into
  cmux-tui/target/hosted/<sha>/ (run from the WORKTREE ROOT - cwd drift has
  corrupted this path before); preflight the EXACT handoff command from
  ~/fun/cmuxterm-hq in tmux with a FRESH session name, running real `codex`
  in a tab and watching the row appear via screen detection (codex hooks do
  not fire - that is the point). Also verify claude still flows via hooks and
  that hook-vs-screen arbitration does not flap states.
- Trade-offs must be listed in the PR body, none absorbed.

## Verification checklist
- Unit: manifest parse of ALL 21 vendored files; region extraction; rule
  priority; any/not; transitions edge-triggered; arbitration matrix
  (hook/screen/socket x fresh/stale); exit removal; ordering.
- Restart: screen-derived entries re-fold from the journal (existing
  rederivation test pattern in mux.rs).
- Live tmux: codex via screen detection end to end; claude unaffected.
