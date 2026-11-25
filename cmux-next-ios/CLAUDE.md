# cmux-next iPhone app: agent notes

For work under `cmux-next-ios/`, the NEXT iPhone app. The root [CLAUDE.md](../CLAUDE.md) still applies.
This is the iPhone app. `ios/` is the retired classic app: don't change or install it. iOS is
Aziz's area (`azooz2003-bit`).

Maintainers: team-specific workflow notes live in the maintainers' private docs.

## See your change: edit to visible

Nothing builds or boots a simulator on the person's Mac (root rule). Pick the fastest route that
covers your change:

| Route | Edit to visible | Use it for |
|---|---|---|
| Simulator step: `scripts/ci/cmux-next-ios-sim.sh build` on a Mac with Xcode (evidence in `artifacts/ios-sim/evidence.zip`) | `build` takes a few minutes; the Rust FFI xcframework is cached by its inputs | PR evidence: `build`, `test` (with `only=`, `ui=`, `video`, `profile`), `bench`; modes are in the script's header |
| Always-on simulator, `scripts/ios-live/ios-live swap` (on `feat-cmux-next` since [#45435](https://github.com/manaflow-ai/cmux/pull/45435), 2026-11-23): your checkout's diff, warm-rebuilt and relaunched | about 16 s | Any change, from any checkout, no simulator step. One driver at a time: `ios-live lease take` before anything that touches the app; `shot`, `tree`, `status`, `log` need no lease. Leave it running. See `scripts/ios-live/README.md` |
| Swift live code, `ios-live swift` / `scripts/live-code/ios-sim.sh patch OUT FILE.swift` ([#45397](https://github.com/manaflow-ai/cmux/pull/45397), `ios-sim.sh` not on `feat-cmux-next` yet; check `ls scripts/live-code/ios-sim.sh`) | about 1.9 s once it lands | DEBUG simulator builds only. Until `ios-sim.sh` is on the branch, `ios-live swift` and `undo` refuse ("not a live code build") and `swap` is the live route. A patch that changes a `some View` type is refused; use `swap` for those |

What CI runs on a PR into `feat-cmux-next` (checked against the workflows on 2026-11-23):

- Kit tests (`cmux-next-ios-kit.yml`, about 17 min): run with no label on a PR touching `cmux-next-ios/**` or
  a package CmuxMobileKit links. `scripts/ci/ios_runner_pool.py` picks one of our Macs (a fork PR gets a
  Blacksmith Mac). A tree that already passed is skipped (same-tree reuse). The instant-list bench steps are
  advisory: they warn, never fail the job.
- App Review gate (`ios-review-gate.yml`): skipped on the PR unless it is labeled `full-ci`; the
  `feat-cmux-next` push after the merge runs it.
- `ios-e2e.yml`: its tailnet jobs skip on PRs while the repo variable `IOS_E2E_PR_TAILNET` isn't `true`; a
  dispatch runs them.
- `billing.yml`: its StoreKit lane runs on a Mac when the PR touches `Packages/iOS/CmuxMobileBilling/**` or
  billing files in the app.
- Most Linux jobs on our own branches run on the `cmux-linux` label (cmux#48644); fork PRs use
  GitHub-hosted `ubuntu-24.04`. A few, such as the kit's `runner` job, still pick from `RUNNER_POOLS`.

## Try a PR on the person's phone: cmux Dev

`cmux-next-ios/scripts/try.sh <PR|branch|sha|.>`, from the Mac the phone is attached to, puts that commit on every
connected iPhone as **cmux Dev** (`dev.cmux.mobile.dev`): the iPhone twin of `cmux app try PR`. One app that
every try replaces in place, so its sign-in and its pairing with the person's NIGHTLY Mac stay; it has no dev tag,
so it shows their real data (the Demo build's rule). A build step makes only the unsigned device app
(`cmux-next-ios-sim.sh try`, keyed by the commit, cached on the Mac); the Mac signs, installs and launches it.
`--sign-in` signs it in with the `personal` profile (first install), `--backend ORIGIN` points it at another
Cloud backend, `try.sh status` lists the last tries and their times.

## Hand-off command

This is the ["Finishing a task"](../skills/cmux-dev-workflow/references/finishing-a-task.md) hand-off for the
iPhone app. Its phone leg passed end to end on 2026-11-18 on a real iPhone 16 Plus (tag
`phone-e2e-1118`, [#46718](https://github.com/manaflow-ai/cmux/pull/46718)) in all three modes:
default, `--manual-pairing` and `--no-auth`. Report any failure as the phone's blocker. It leaves the task's build on every connected iPhone,
signed in and paired with the same-tag Mac build, from one command at the pushed head:

```bash
cmux-next-ios/scripts/review.sh --tag <task-slug> [--target-worker <simulator worker>] [--manual-pairing | --approve-first | --no-auth] [--backend dev|tag-stack|<origin>]
```

When the person is waiting on the phone right now, add `--urgent`: the iPhone step goes ahead of the
simulator queue and the Mac build moves up the Mac queue, each logged with the reason. An agent's own
end-of-task run does not use it. A step that ends because no sign-in session reached it from this Mac
is sent once more by itself.

**Backend.** Both apps talk to the tag's own backend stack by default. `review.sh` runs
`scripts/cmux-next/cloud-dev-stack.sh up --tag <task-slug>` beside the builds, then:
- the Mac app gets the stack's tailnet origin (`backend.json`);
- the phone gets its public origin, `https://api.s<N>.wdev.cmux.dev`, which works off the tailnet
  behind the authenticating gateway. Its readiness receipt must name the stack's mobile Worker. When
  every public slot is held, the phone gets the tailnet origin too, and the `Backend:` line says
  "tailnet only".

The report's `Backend:` line names both. An `up` that fails falls back to the shared dev Workers,
with the reason on that line. `--backend dev` keeps the shared dev Workers and touches no stack.
`--backend tag-stack` uses the stack as it is, with no `up`. The allowlist and its threat model:
[SECURITY.md](SECURITY.md), "A tag's own Cloud backend".

The default is the rule for every dev build on a phone: signed in with the `personal` account and
paired with the same-tag Mac at once, and still both after the person relaunches the app or the
Mac. Those relaunches run the app's production persistence path: a launch with no
`CMUX_MOBILE_STACK_*` has no auto-login credentials, so the session comes back from the Keychain
token store the same way it does in Release, and the pairing state is the app's own. The
flags are for checking the other paths, and are never the hand-off:

| Flag | The phone | The proof | Its report line |
| --- | --- | --- | --- |
| (none) | signed in, paired with the tagged Mac (its dev auto-approve; the launch names the Mac to focus) | signed in, paired, linked; again after a credential-free relaunch, through TURN after a relay-only relaunch, and after the Mac app restarts | `installed, signed in (auto_login), paired and linked with <Mac> over WireGuard, direct LAN; ...; relay-only relaunch (TURN only, as a phone away from home): ... via TURN; ...` |
| `--manual-pairing` | signed in; no Mac named, so the person picks and pairs by hand | signed in, and still after a credential-free relaunch; no pairing checks, no Mac restart | `installed, signed in (auto_login); credential-free relaunch: signed in (restored); pairing left to you (--manual-pairing)` |
| `--approve-first` | signed in; the tagged Mac starts (again, if it runs) with `CMUX_NEXT_IPHONE_APPROVE_FIRST=1`, so its dev auto-approve is off and it shows "Allow “<phone>” (<key>) to connect to this Mac?" | the phone picks the tagged Mac; the Mac itself shows the request and the prompt (`review_mac.py allow-state`), said before the wait with the Mac's name and app; the person's Allow pairs it (`CNX_REVIEW_ALLOW_TIMEOUT`, 600 s); then a credential-free relaunch is linked and the Mac lists it paired and connected; no Mac restart. A phone that Mac paired before is reported "not asked" | `installed, signed in (auto_login), asked the tagged Mac “<Mac>” (cmux DEV <tag>), which showed “Allow …”; allowed on the Mac (--approve-first); credential-free relaunch: ...`, or unattended `waiting for Allow on the Mac: nobody pressed Allow in 600 s. The tagged Mac “<Mac>” (cmux DEV <tag>) shows “Allow …”, and the phone is signed in and waiting for it, not linked yet. Next: ...` |
| `--no-auth` | no credentials, no Mac named; the first launch clears the tag's stored session with the DEBUG-only `CMUX_MOBILE_CLEAR_AUTH=1` (compiled out of Release) | the receipt says signed out (welcome screen), and a plain relaunch is still signed out | `installed, not signed in (--no-auth): ...; relaunch: still signed out` |

A tagged dev Mac (DEBUG `com.cmuxterm.app.debug.<tag>`) pairs its own tag's iPhone app
(`dev.cmux.mobile.<tag>`) of the signed-in account without the Allow prompt, so a phone opened by
hand or through the Tag Opener link pairs at once too; a machine, another account or another tag's
phone still asks, and another build's dev iPhone app asks NIGHTLY, release and other tags only
quietly (Settings > Mobile, no prompt). `--approve-first` turns it off for the run, to check the
Allow prompt itself; a phone already paired with that Mac is not asked again (remove it in Settings
> Mobile first). The readiness receipt's `paired_macs` is the phone's focused Mac (picked from the
account's Mac list), not a Mac that let it in: only `linked: true` means paired, and the hand-off never
calls a Mac it merely picked "paired". The rules and their safety argument: [SECURITY.md](SECURITY.md) "Dev auto-approve".

`--no-auth` implies no pairing; given both, `--no-auth` wins.

Every linked verdict names how the link travels, from the receipt's focused Mac (`transport`, `path`,
`tailnet`; `DogfoodReadiness.Route`): `over WireGuard, direct LAN`, `direct over the tailnet`,
`direct over the internet`, `via TURN` or `via TURN over TLS`. Every build dials WireGuard and offers
each interface's addresses, Tailscale's 100.64.0.0/10 ones too, so with Tailscale on the phone and the
Mac a link at home can ride the tailnet, a path no user without Tailscale takes. The relay-only
relaunch (the default mode, after the credential-free one) is that same cold launch plus only
`CMUX_MOBILE_DEV_RELAY_ONLY=1`, which makes the Rust link skip every direct path: it must link via
TURN, the path a phone away from home takes. `--forbid-tailnet` (any mode) makes a tailnet path a
failure: `linked with <Mac> over the tailnet (--forbid-tailnet): ...`.

It does, in order, and exits non-zero if any phone fails a check or none is connected:

1. Builds at the pushed head: the tagged cmux NEXT Mac app (Tag Opener
   `http://127.0.0.1:17320/<task-slug>`), and in one simulator step
   (`cmux-next-ios-sim.sh handoff tag=<task-slug>`) the iPhone app (Demo configuration with the
   DEBUG developer surface, bundle `dev.cmux.mobile.<task-slug>`, home-screen name
   "cmux <task-slug>", the tag's cloud build space `dev:<task-slug>` like its Mac's, an unsigned device app) plus the simulator check: signed in with the
   agent account's session (from your Mac, `--sign-in agent`), relaunched with no credentials and
   signed in again from its own session, with screenshots and a recording. Rerunning resumes the saved jobs.
2. Installs the tagged Mac app at the tag's path and starts it in the background (`open -g`,
   never frontmost), signed in to the `personal` account.
3. On every connected, paired iPhone (new phones are registered): signs a copy with this Mac's
   Apple Development identity and a development profile that names the phone, installs it through
   the sanctioned install, and launches it signed in with the `personal` profile and the
   tagged Mac named to focus (`CMUX_MOBILE_FOCUS_MAC`, a device id). The tagged Mac's dev auto-approve
   allows its own tag's phone (no Allow prompt, no seed, no code).
4. Proves each phone with the app's DEBUG readiness receipt (a fresh nonce per launch): in the tagged
   Mac's build space (`review_mac.py space`; another space fails at once), signed in, paired and linked with this tag's Mac, which lists the phone as paired and connected; then a
   credential-free relaunch (the person's own cold launch) comes back signed in and linked; then a
   relay-only relaunch links via TURN; then the Mac app quits as the person quits it and starts
   again, and each phone links to it again. Each verdict names the link's path.
5. Prints the report, in the root "Finishing a task" format:

```text
Dev build:  http://127.0.0.1:17320/<task-slug>   (fleet job <id>, published to HQ, head <sha>)
Simulator:  fleet simulator (<worker>, <device>), signed in (agent account), restored after a credential-free relaunch: <evidence dir> (...)
iPhone:     <name> (<model>, <udid>): installed, signed in (auto_login), paired and linked with <Mac> over WireGuard, direct LAN; ...; relay-only relaunch (TURN only, as a phone away from home): signed in (restored), paired and linked with <Mac> over WireGuard, via TURN; after the Mac app relaunched: signed in (restored), paired and linked with <Mac> over WireGuard, direct LAN
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
- A simulator worker for the simulator step. It needs no agent account file: the step reads a
  session signed in for it alone with `scripts/lib/fleet-signin-session.sh`.

Its scripts: `scripts/review.sh` (the command), `scripts/sign_device_app.py` (local signing),
`scripts/review_mac.py` (the tagged Mac over its control socket), `scripts/handoff_receipt.py`
(the receipt check), `CmuxMobileKit/Sources/CmuxMobileShell/DogfoodReadiness.swift` (the DEBUG
receipt). Their Linux tests: `python3 ios/tests/test_cnx_review.py`.

## Terminal on iPhone

- **Projection** ([#49901](https://github.com/manaflow-ai/cmux/pull/49901), the default): the
  phone re-wraps the Mac's terminal text at its own width, and the Mac pane keeps its grid. The phone
  claims a size only for the exception, a full-screen app on the alternate screen, and releases it
  when the app exits. Settings → Terminal → Fit to Phone (off by default) keeps the old resize, and the
  terminal page's menu toggles it per program. It is the default because its cell-by-cell parity
  harness is green in CI ("cargo test (terminal projection parity)", `cmux-next-terminal.yml`). The logic
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
