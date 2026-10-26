# Chief fast evals

The inner loop for Chief behavior: real Chief brain (optchat-chief native
engine, production system prompt, real OptChat memory and view), no Mac app,
on Linux, under 2 minutes. Design: plans/cmux-next/agent-evals-DESIGN.md,
section "Chief fast evals".

Run: `Native/OptChat/optchat-chief/evals/run.sh` (all cases), or
`run.sh --only links-` (id prefix), `--repeat 3` (each model case 3 times),
`--no-model` (deterministic only), `--ledger pre` (the reply ledger as it was
before 2026-10-26, for A/B), `--min-pass 0.8` (gate on a pass fraction).
Model cases need `OPTCHAT_ANTHROPIC_BASE_URL`: the team subrouter
(`http://100.89.225.106:31415`, what CI uses) or the sr2 gateway
(`http://100.120.48.119:4016`, reachable from cmux-lawrence). Requests are
Claude Code shaped (its system line and user agent), as production turns are.
`chief_eval preflight` checks the route. Deterministic cases need nothing.
Run it on a mini or Linux box, not the laptop: `ulimit -n 8192` first (each
case opens a memory database; run.sh does it).

## Two kinds of case

1. **Model cases**: one JSON file per case in `evals/cases/` (`<group>-<name>.json`).
   The runner (`cargo run --release --example chief_eval`) seeds a fresh
   memory, runs each turn through the real native engine, and grades.
2. **Deterministic cases**: Rust integration tests named `tests/eval_*.rs`
   (for host behavior with no model call, e.g. a stuck-agent alert). The
   runner runs `cargo test --test 'eval_*'` and counts each `#[test]` as one
   case, group = file name after `eval_`.

Add a case = add a file. Never edit another owner's file.

## Model case format

```json
{
  "id": "links-workspace-spawn",
  "group": "links",
  "owner": "a674",
  "about": "one line: what behavior this guards",
  "history": [
    {"kind": "user", "text": "older message, seeded into memory before the turns"},
    {"kind": "talk", "text": "Chief's earlier reply"},
    {"kind": "work", "text": "[a12] report text"},
    {"kind": "note", "text": "a memory"}
  ],
  "stubs": [
    {"cmd": "cmux", "match": "workspace list", "stdout": "{...}", "exit": 0},
    {"cmd": "chief", "match": "spawn", "stdout": "a13: workspace ws_abc (cmux://workspace/ws_abc)"},
    {"cmd": "gh", "match": "pr view", "stdout": "..."}
  ],
  "turns": [
    {
      "kind": "user",
      "text": "the new message (kind defaults to user; any history kind works, e.g. work for a subagent report)",
      "checks": [
        {"type": "reply_matches", "re": "\\[[^\\]]+\\]\\(cmux://workspace/ws_abc\\)"},
        {"type": "no_raw_ids"},
        {"type": "called", "cmd": "chief", "match": "spawn"},
        {"type": "not_called", "cmd": "cmux", "match": "workspace close"},
        {"type": "max_words", "n": 80},
        {"type": "no_question"},
        {"type": "judge", "rubric": "Passes when ... Fails when ..."}
      ]
    }
  ]
}
```

- `stubs`: `cmux`, `chief`, `gh`, `cmux-ci`, `curl`, `stripe` (any name) are
  shims on the turn's PATH. A call whose argv (joined by spaces) contains
  `match` prints `stdout` and exits `exit` (first match wins); no match prints
  nothing and exits 0. Every call is logged and is what `called` /
  `not_called` grade (`match` is a substring of the joined argv; `re` works
  too).
- MCP tools (`spawn`, `tell`, `send`, `reply`, `react`, `control`,
  `remember`, `sleep`, `stop`, ...) are logged the same way, with
  `cmd` = the tool name and `argv` = its JSON input; a stub with that `cmd`
  overrides the default answer. `zoom`, `date` and `transcript` answer from
  the case's real memory. `stop`/`sleep` end the turn and drop text after
  the last send, as the brain does; with a person message still unanswered
  they are refused (the reply ledger), and a turn that ends unanswered gets
  the brain's `[no reply]` retry turn (counted in `retry_turns`, +5 s).
- Checks (all posted text of the turn, retry included): `reply_matches` /
  `reply_not_matches` (Rust `regex` crate: no look-around or backreferences), `no_raw_ids` (no ws_/tab_/pane_ id,
  sha, URL, path or #NNN outside a Markdown link), `posted`, `silent`
  (nothing posted), `called` / `not_called` (`cmd`, `match` substring and/or
  `re`), `max_calls` (`cmd`, `n`), `max_words`, `no_question` (no line ends
  in "?"), `file_contains` (`path` under the case home, `re`), `judge`
  (`rubric`; Sonnet answers PASS/FAIL and a reason). A turn passes when all
  its checks pass; a case when all its turns pass.
- Case fields: `person` (profile text; default `evals/person.md`), `files`
  (path under the case home -> text), `channels: true` (the Chief reads
  every message of its group chats: the brain's Channels paragraph is in its
  prompt), `settle: false` (the first turn starts while the compactor still
  summarizes the history: summary lag). Turn fields: `tail` (per-turn state
  after the delta, e.g. `Subagents at work now: a12.`), `also` (more
  messages in the same turn).
- Group chats: `"conv": "Launch planning", "author": "Leo"` (and
  `"author_kind": "Chief"`) labels an item as the brain labels side
  messages: `[in conv conv_… "Launch planning" from person "Leo"] text`.

## Numbers (summary.json)

Per run: pass count per group, wall time, turn latency p50/p90 (wake to the
turn's end, retry turn included), first request latency, requests per turn,
input/output tokens per turn, cache hit (cache read / all input), `retry_turns`
and `unsummarized_max` (placeholder lines in the view a turn read: summary
lag).
