# cmux-next iPhone app: agent notes

For work under `cmux-next-ios/`, the NEXT iPhone app. The root [CLAUDE.md](../CLAUDE.md) still applies.
`ios/` is the classic app, with its own [ios/AGENTS.md](../ios/AGENTS.md). iOS is Aziz's area
(`azooz2003-bit`).

**Manaflow AI team members and their agents:** also read the private
[cmux-next-ios skill](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/skills/ios/cmux-next-ios/SKILL.md)
in cmuxterm-hq. It has the fleet hosts, the open iOS work and who to message. Ask there before
starting something another agent may already have open. External contributors can skip it; the
link returns 404 for them.

## See your change: edit to visible

Nothing builds or boots a simulator on the person's Mac (root rule). Pick the fastest route that
covers your change:

| Route | Edit to visible | Use it for |
|---|---|---|
| Fleet simulator step: `cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA --arg build --artifact artifacts/ios-sim/evidence.zip` | about 15 min (queue median about 8 min) | PR evidence: `build`, `test` (with `only=`, `ui=`, `video`, `profile`), `bench`; modes are in the script's header |
| Swift live code, `scripts/live-code/ios-sim.sh patch OUT FILE.swift` ([#45397](https://github.com/manaflow-ai/cmux/pull/45397), draft) | about 1.9 s | DEBUG simulator builds only. A patch that changes a `some View` type (a view or modifier added or removed) is refused; rebuild for those |
| Always-on simulator, `scripts/ios-live/ios-live` ([#45435](https://github.com/manaflow-ai/cmux/pull/45435), once it lands) | 1.9 s live, about 16 s rebuild | One driver at a time: `ios-live lease take` before anything that touches the app; `shot`, `tree`, `status`, `log` need no lease. Leave it running. See `scripts/ios-live/README.md` |

## Terminal on iPhone

- **Projection** ([#42219](https://github.com/manaflow-ai/cmux/pull/42219), open): the
  phone re-wraps the Mac's terminal text at its own width, and the Mac pane keeps its grid. The phone
  claims a size only for the exception, a full-screen app on the alternate screen, and releases it
  when the app exits. Settings → Terminal → Fit to Phone (off by default) keeps the old resize. The logic
  is Rust (the `cmux-terminal-projection` crate); Swift is glue. Size claims:
  [PROTOCOL.md](PROTOCOL.md), "Terminal size claims".
- **Lean agent-CLI view** ([#44052](https://github.com/manaflow-ai/cmux/pull/44052), off by default,
  Settings → Transport → Agent CLI Screen Changes): the Mac sends an agent CLI's changed cells, and
  the phone draws them in its own terminal. A frame it can't draw falls back to the byte stream. Its
  proofs (parity, fuzz, pixel diff, old viewers) and the pixel matrix
  ([#45266](https://github.com/manaflow-ai/cmux/pull/45266)) stay green with any change to either side.
- **Scrollback window** ([#43189](https://github.com/manaflow-ai/cmux/pull/43189)): the Mac keeps the
  scrollback, and the phone holds a window of it.

## Landing an iOS PR

A PR that changes iOS code waits for Aziz's review. It lands without him only when it's proven
correct and fully functional, with its implications written in the PR. merge_hold reads one line in
the PR body:

- `iOS-hold: strict fix`: a basic correctness fix, plus an independent review SHIP at the exact head
  that confirms it.
- `iOS-hold: proven`: a test that fails without the change and passes with it (run links), the flow
  working end to end in a simulator or on a device, a `## Implications` section, and a review SHIP at
  the exact head that confirms all three.

A change that flips a default stays with Leo. Docs (`*.md`) and `cmux-next-ios/verify/` hold nothing.
Either way, post a comment on the PR that mentions Aziz so he knows it's coming.
