# cmux-next-ios/ agent instructions

This is the cmux-next iPhone app (`CmuxMobileApp`, XcodeGen `project.yml`, dev bundles
`dev.cmux.mobile.<tag>`). `ios/` is the classic cmux iPhone app; its instructions
([ios/AGENTS.md](../ios/AGENTS.md)) and `ios/scripts/reload.sh --review` are for that app only.
Read [PLAN.md](PLAN.md) for the layout and [SECURITY.md](SECURITY.md) before changing pairing,
the Mac link or anything a phone may do on a Mac. Agents never build, test or boot a simulator
on the person's Mac: Swift and Rust builds and the simulator run on the fleet
(`scripts/ci/cmux-next-ios-sim.sh`, a `cmux-ci run --class simulator` step).
`scripts/demo-build.sh` builds on the Mac it runs on: it is for people, not agents.

## Hand-off command (under verification)

`scripts/review.sh` is new: its phone leg has not yet run end to end (the fleet runs its
`handoff` step only once it is on feat-cmux-next). Until one green end-to-end run, the root
[AGENTS.md](../AGENTS.md#finishing-a-task) "Finishing a task" rules stay as they are; use this
command and report its output beside them. It leaves the task's build on every connected iPhone,
signed in and paired with the same-tag Mac build, from one command at the pushed head:

```bash
cmux-next-ios/scripts/review.sh --tag <task-slug> [--target-worker <simulator worker>]
```

It does, in order, and exits non-zero if any phone fails a check or none is connected:

1. Builds on the fleet at the pushed head: the tagged cmux NEXT Mac app (`cmux-ci build cmux`,
   published to HQ, Tag Opener `http://127.0.0.1:17320/<task-slug>`), and in one simulator step
   (`cmux-next-ios-sim.sh handoff tag=<task-slug>`) the iPhone app (Demo configuration with the
   DEBUG developer surface, bundle `dev.cmux.mobile.<task-slug>`, home-screen name
   "cmux <task-slug>", an unsigned device app) plus the fleet simulator check: signed in with the
   worker's agent account, relaunched with no credentials and signed in again from its own session,
   with screenshots and a recording. Rerunning resumes the saved jobs.
2. Installs the tagged Mac app at the tag's path and starts it in the background (`open -g`,
   never frontmost), signed in to the `personal` account.
3. On every connected, paired iPhone (new phones are registered): signs a copy with this Mac's
   Apple Development identity and a development profile that names the phone, installs it through
   the sanctioned install, and launches it signed in with the `personal` profile and the tagged
   Mac's own single-use pairing code, the code a scan would open (no Allow prompt, no seed).
4. Proves each phone with the app's DEBUG readiness receipt (a fresh nonce per launch): signed in,
   paired and linked with this tag's Mac, which lists the phone as paired and connected; then a
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
- A fleet simulator worker with the agent account (`<host dir>/secrets/ios-agent-stack.env`). The
  step asks for `--label ios-agent-signin`, which only such workers advertise; with none online it
  waits in the queue.

Its scripts: `scripts/review.sh` (the command), `scripts/sign_device_app.py` (local signing),
`scripts/review_mac.py` (the tagged Mac over its control socket), `scripts/handoff_receipt.py`
(the receipt check), `CmuxMobileKit/Sources/CmuxMobileShell/DogfoodReadiness.swift` (the DEBUG
receipt). Their Linux tests: `python3 ios/tests/test_cnx_review.py`.
