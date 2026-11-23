# cmux-next iPhone app: agent notes

For work under `cmux-next-ios/`, the NEXT iPhone app. The root [CLAUDE.md](../CLAUDE.md) still applies.
This is the iPhone app. `ios/` is the retired classic app: don't change or install it. iOS is
Aziz's area (`azooz2003-bit`).

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
| Swift live code, `scripts/live-code/ios-sim.sh patch OUT FILE.swift` ([#45397](https://github.com/manaflow-ai/cmux/pull/45397), open; not on `feat-cmux-next` yet) | about 1.9 s | DEBUG simulator builds only. A patch that changes a `some View` type (a view or modifier added or removed) is refused; rebuild for those |
| Always-on simulator, `scripts/ios-live/ios-live` ([#45435](https://github.com/manaflow-ai/cmux/pull/45435), once it lands) | 1.9 s live, about 16 s rebuild | One driver at a time: `ios-live lease take` before anything that touches the app; `shot`, `tree`, `status`, `log` need no lease. Leave it running. See `scripts/ios-live/README.md` |

### From a lane VM (Linux, no Mac)

A lane VM has no Xcode, but every step below runs from it through the fleet. Push your branch
first: each command takes the exact pushed SHA.

```bash
SHA=$(git rev-parse HEAD)   # pushed

# 1. Compile a Swift package the kit links (Packages/iOS/*, Packages/Shared/*): bare name, repeatable.
cmux-ci compile-check --ref "$SHA" --package CmuxMobileShellModel

# 2. Run one kit test suite on a fleet iPhone simulator (TARGET/SUITE or TARGET/SUITE/test).
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA" \
  --arg test --arg only=CmuxMobileLiveTests/LinkRecoveryTests --artifact artifacts/ios-sim/evidence.zip

# 3. One simulator screenshot of the app at launch.
cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref "$SHA" \
  --arg build --artifact artifacts/ios-sim/evidence.zip
cmux-ci artifact STEP_ID /tmp/ev/evidence.zip   # STEP_ID is printed when the step ends
cd /tmp/ev && unzip -q evidence.zip              # screens/launch.png, SUMMARY.md, build.log, app-log.txt
```

Measured from a lane VM on 2026-11-22: step 1 took 4 min 2 s end to end (36 s of compiling, the rest
queue; job `7b91777edac21acc8f892f3a`); step 3 took 39 min 41 s end to end on a fleet simulator Mac (the
Rust FFI xcframework missed its cache and took 308 s; FFI plus app build 581 s; the rest was queue,
boot and install). The FFI is cached by its inputs, so a Swift-only change skips those 308 s.
A PR into `feat-cmux-next` that touches `cmux-next-ios/**` also runs the whole kit
(`cmux-next-ios-kit.yml`, about 18 min on a Blacksmith macOS runner) without a label.

## Try a PR on the person's phone: cmux Dev

`cmux-next-ios/scripts/try.sh <PR|branch|sha|.>`, from the Mac the phone is attached to, puts that commit on every
connected iPhone as **cmux Dev** (`dev.cmux.mobile.dev`): the iPhone twin of `cmux app try PR`. One app that
every try replaces in place, so its sign-in and its pairing with the person's NIGHTLY Mac stay; it has no dev tag,
so it shows their real data (the Demo build's rule). The fleet builds only the unsigned device app
(`cmux-next-ios-sim.sh try`, keyed by the commit, cached on the Mac); the Mac signs, installs and launches it.
`--sign-in` signs it in with the `personal` profile (first install), `--backend ORIGIN` points it at another
Cloud backend, `try.sh status` lists the last tries and their times. Design and phases (built ahead, the in-app
Try PR picker, Swift hot patches on the device): cmuxterm-hq `docs/design/ios-dev-channels.md`.

Built ahead: every head of a same-repository iPhone PR into `feat-cmux-next` runs the `cmux Dev try build (ahead)`
check (`.github/workflows/cmux-next-ios-try-ahead.yml`), the same fleet step under the same key try.sh asks for, so
`try.sh N` then only downloads, signs and installs. In cmux Dev, Settings > Developer > Try a Pull Request lists the
open iPhone PRs (`try.sh list`) with their build state and installs one through the Mac's hostd (`try-pr`,
PROTOCOL.md). That Mac needs the script linked once: `ln -s <checkout>/cmux-next-ios/scripts/try.sh ~/.config/cmux/try.sh`
(or `CMUX_MOBILE_TRY_SH`), with gh signed in and the cmux-ci client installed.

## Hand-off command

This is the ["Finishing a task"](../skills/cmux-dev-workflow/references/finishing-a-task.md) hand-off for the
iPhone app. Its phone leg passed end to end on 2026-11-18 on a real iPhone 16 Plus (tag
`phone-e2e-1118`, [#46718](https://github.com/manaflow-ai/cmux/pull/46718)) in all three modes:
default, `--manual-pairing` and `--no-auth`. Report any failure as the phone's blocker. It leaves the task's build on every connected iPhone,
signed in and paired with the same-tag Mac build, from one command at the pushed head:

```bash
cmux-next-ios/scripts/review.sh --tag <task-slug> [--target-worker <simulator worker>] [--manual-pairing | --approve-first | --no-auth]
```

The default is the rule for every dev build on a phone: signed in with the `personal` account and
paired with the same-tag Mac at once, and still both after the person relaunches the app or the
Mac. Those relaunches run the app's production persistence path: a launch with no
`CMUX_MOBILE_STACK_*` has no auto-login credentials, so the session comes back from the Keychain
token store the same way it does in Release, and the pairing state is the app's own. The
flags are for checking the other paths, and are never the hand-off:

| Flag | The phone | The proof | Its report line |
| --- | --- | --- | --- |
| (none) | signed in, paired by the Mac's code | signed in, paired, linked; again after a credential-free relaunch and after the Mac app restarts | `installed, signed in (auto_login), paired and linked with <Mac>; ...` |
| `--manual-pairing` | signed in; no code handed over or marked used, so the person pairs by hand | signed in, and still after a credential-free relaunch; no pairing checks, no Mac restart | `installed, signed in (auto_login); credential-free relaunch: signed in (restored); pairing left to you (--manual-pairing)` |
| `--approve-first` | signed in; no code; the tagged Mac starts (again, if it runs) with `CMUX_NEXT_IPHONE_APPROVE_FIRST=1`, so its dev auto-approve is off and it shows "Allow “<phone>” to connect?" | waits for the person's Allow on the Mac (`CNX_REVIEW_ALLOW_TIMEOUT`, 600 s), then paired, linked, listed by the Mac, and again after a credential-free relaunch; no Mac restart | `installed, signed in (auto_login), paired and linked with <Mac> (allowed on the Mac, --approve-first); ...`, or `waiting for Allow on the Mac: not paired in time (...)` |
| `--no-auth` | no credentials, no code; the first launch clears the tag's stored session with the DEBUG-only `CMUX_MOBILE_CLEAR_AUTH=1` (compiled out of Release) | the receipt says signed out (welcome screen), and a plain relaunch is still signed out | `installed, not signed in (--no-auth): ...; relaunch: still signed out` |

A tagged dev Mac (DEBUG `com.cmuxterm.app.debug.<tag>`) pairs its own tag's iPhone app
(`dev.cmux.mobile.<tag>`) of the signed-in account without the Allow prompt, so a phone opened by
hand or through the Tag Opener link pairs at once too; a machine, another account or another tag's
phone still asks, and another build's dev iPhone app asks NIGHTLY, release and other tags only
quietly (Settings > Mobile, no prompt). `--approve-first` turns it off for the run, to check the
Allow prompt itself; a phone already paired with that Mac is not asked again (forget it in Settings
> Mobile first). The rules and their safety argument: [SECURITY.md](SECURITY.md) "Dev auto-approve".

`--no-auth` implies no pairing; given both, `--no-auth` wins.

It does, in order, and exits non-zero if any phone fails a check or none is connected:

1. Builds on the fleet at the pushed head: the tagged cmux NEXT Mac app (`cmux-ci build cmux`,
   published to HQ, Tag Opener `http://127.0.0.1:17320/<task-slug>`), and in one simulator step
   (`cmux-next-ios-sim.sh handoff tag=<task-slug>`) the iPhone app (Demo configuration with the
   DEBUG developer surface, bundle `dev.cmux.mobile.<task-slug>`, home-screen name
   "cmux <task-slug>", the tag's cloud build space `dev:<task-slug>` like its Mac's, an unsigned device app) plus the fleet simulator check: signed in with the
   agent account's session (from your Mac, `--sign-in agent`), relaunched with no credentials and
   signed in again from its own session, with screenshots and a recording. Rerunning resumes the saved jobs.
2. Installs the tagged Mac app at the tag's path and starts it in the background (`open -g`,
   never frontmost), signed in to the `personal` account.
3. On every connected, paired iPhone (new phones are registered): signs a copy with this Mac's
   Apple Development identity and a development profile that names the phone, installs it through
   the sanctioned install, and launches it signed in with the `personal` profile and the tagged
   Mac's own single-use pairing code, the code a scan would open (no Allow prompt, no seed).
4. Proves each phone with the app's DEBUG readiness receipt (a fresh nonce per launch): in the tagged
   Mac's build space (`review_mac.py space`; another space fails at once), signed in, paired and linked with this tag's Mac, which lists the phone as paired and connected; then a
   credential-free relaunch (the person's own cold launch) comes back signed in and linked; then
   the Mac app quits as the person quits it and starts again, and each phone links to it again.
5. Prints the report, in the root "Finishing a task" format:

```text
Dev build:  http://127.0.0.1:17320/<task-slug>   (fleet job <id>, published to HQ, head <sha>)
Simulator:  fleet simulator (<worker>, <device>), signed in (agent account), restored after a credential-free relaunch: <evidence dir> (...)
iPhone:     <name> (<model>, <udid>): installed, signed in (auto_login), paired and linked with <Mac>; ...; after the Mac app relaunched: signed in (restored), paired and linked with <Mac>
```

A phone line that says `BLOCKED: <reason>; retry: <command>` is a blocker to report as it is.
Never install the app with raw `devicectl`, skip a phone, or replace the phone with the simulator.

What it needs:

- iPhone connections on in the person's cmux-next (Settings > Mobile > Allow iPhone connections,
  `mobile.allowIPhoneConnections`). The setting lives in the shared `~/.config/cmux/cmux-next.json`
  that every build reads, so a fresh tag starts with the person's choice. Only the person turns it
  on; when it is off, `review.sh` reports that as the blocker.
- The `personal` profile in `~/.secrets/cmuxterm-dev.env` and `~/.config/cmux/dev-account` naming
  it, so the tagged Mac signs in to the same account as the phone (`scripts/setup-team-dev.sh`).
- A development profile on this Mac for each bundle (the app and its two notification
  extensions) that names each phone; the team wildcard profile covers all three. A phone no
  profile names gets a `BLOCKED: signing failed` line: register it in the team first. The phone
  needs Developer Mode, to be unlocked, and to trust this Mac. No Tailscale.
- A fleet simulator worker. It needs no agent account file: the step is sent with
  `cmux-ci run --sign-in agent`, which signs the shared agent
  account in on this Mac for that step alone, seals it to the worker, and revokes it when the step
  ends (hq build-fleet `sign_in`; the step reads it with `scripts/lib/fleet-signin-session.sh`).
  `cmux-ci run` follows the step while it delivers the session, so review.sh never detaches it.

Its scripts: `scripts/review.sh` (the command), `scripts/sign_device_app.py` (local signing),
`scripts/review_mac.py` (the tagged Mac over its control socket), `scripts/handoff_receipt.py`
(the receipt check), `CmuxMobileKit/Sources/CmuxMobileShell/DogfoodReadiness.swift` (the DEBUG
receipt). Their Linux tests: `python3 ios/tests/test_cnx_review.py`.

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
