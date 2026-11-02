# Chief fast evals

The inner loop for Chief behavior: real Chief brain (optchat-chief native
engine, production system prompt, real OptChat memory and view), no Mac app,
on Linux, under 2 minutes. Design: plans/cmux-next/agent-evals-DESIGN.md,
section "Chief fast evals".

Run: `Native/OptChat/optchat-chief/evals/run.sh` (all cases), or
`run.sh --only links-` (id prefix), `--repeat 3` (each model case 3 times),
`--no-model` (deterministic only), `--ledger pre` (the reply ledger as it was
before 2026-10-26, for A/B), `--min-pass 0.8` (gate on a pass fraction),
`--baseline DIR_OR_SUMMARY_JSON` (diff against an earlier run, below).
Model cases need `OPTCHAT_ANTHROPIC_BASE_URL`: the team subrouter
(`http://100.89.225.106:31415`, what CI uses) or the sr2 gateway
(`http://100.120.48.119:4016`, reachable from cmux-lawrence). Requests are
Claude Code shaped (its system line and user agent), as production turns are.
`chief_eval preflight` checks the route. Deterministic cases need nothing.
Run it on a mini or Linux box, not the laptop: `ulimit -n 8192` first (each
case opens a memory database; run.sh does it).

## Health of a real Chief (no model)

`measure/chief_health.py` reads a Chief home's memory and traces, read-only,
in about a second, and prints the numbers the person feels for the last 7 days
and for all time: time to first reply, messages with no reply, "hello?" pings
while waiting, turns cut by restarts and turn failures, compactor refusal
lines, "No such tool" calls, `cmux` usage errors by command, and spawns
without a workspace. `--home DIR` picks the home's `optchat/` (default the
default Chief), `--since 2w` the window, `--json` the output for diffs. Test:
`python3 -m unittest test_chief_health` (from `measure/`).

## Replays of a person's real messages

`measure/replay_cases.py` turns messages from a real Chief memory into model
cases for this runner, judged by rules only: dispatch fidelity (a spawn in the
repo directory the person accepted, with their words and a Title line), feedback
to action (a bug report becomes a spawn with their words) and rules stick (a
rule taught earlier in the memory holds on a later dispatch, with a profile that
lacks it). A message becomes a case only when Chief spawned for it then and the
person's next message was not a correction. The cases hold real words, so the
script refuses an output directory inside a git work tree: keep them private
and run `evals/run.sh --cases DIR`. Test: `python3 -m unittest test_replay_cases`.

## Two kinds of case

1. **Model cases**: one JSON file per case in `evals/cases/` (`<group>-<name>.json`).
   The runner (`cargo run --release --example chief_eval`) seeds a fresh
   memory, runs each turn through the real native engine, and grades.
2. **Deterministic cases**: Rust integration tests named `tests/eval_*.rs`
   (for host behavior with no model call, e.g. a stuck-agent alert). The
   runner runs `cargo test --test 'eval_*'` and counts each `#[test]` as one
   case, group = file name after `eval_`.

Add a case = add a file. Never edit another owner's file.

## Adding a model case

1. Pick the group the behavior belongs to (table in
   plans/cmux-next/agent-evals-DESIGN.md, "Groups and owners"; a new group
   is just a new prefix, add a row there).
2. Copy the closest case in `evals/cases/` to `<group>-<name>.json`, set
   `id` to the file name, `owner` to your agent or login and `about` to the
   one line it guards.
3. Write the `history` the turn needs, `stubs` for every command whose
   output matters, and the turn with its `checks`. Prefer deterministic
   checks (`called`, `reply_matches`, `no_raw_ids`, `max_words`); add a
   `judge` rubric only for what no regex can say, worded as "Passes when ...
   Fails when ...".
4. Run it alone a few times: `evals/run.sh --only <group>-<name> --repeat 3`.
   A case that fails on today's Chief for the reason it guards is a finding;
   one that fails for another reason (a stub missing, a regex too strict)
   needs fixing before it lands.

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

## Baseline diff

`summary.json` holds each case's result (`case_results`: group, passed,
runs, with `--repeat` folded into one id) and each group's pass rate
(`group_pass_rate`). Every run prints the pass rate per group. With
`--baseline` naming an earlier run's directory or `summary.json`, it also
prints, and writes to `diff.md` and `diff.json`, the pass rate per group
before and after and in total, counted over the cases both runs have (an
`--only` run compares like for like; an old baseline without per-case
results compares the groups both runs have), the cases that regressed,
improved, are new or are missing, and the groups this run left out. Summaries from before `case_results` diff by group only.
The diff is a report; the exit code still follows `--min-pass`.

    evals/run.sh --out /tmp/before            # on the old commit
    evals/run.sh --baseline /tmp/before       # on the new one

In CI, every run that reaches the model cases diffs against the last
feat-cmux-next run with a `chief-evals` artifact. To run it on demand, use
Actions, chief-evals, Run workflow; `baseline_run` picks another run id as
the baseline. The diff is in the job summary.

## Numbers (summary.json)

Per run: pass count per group, wall time, turn latency p50/p90 (wake to the
turn's end, retry turn included), first request latency, requests per turn,
input/output tokens per turn, cache hit (cache read / all input), `retry_turns`
and `unsummarized_max` (placeholder lines in the view a turn read: summary
lag).
