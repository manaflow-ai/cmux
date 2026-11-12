# Cloud workspaces and cloud orchestration for cmux-next

Status: plan, 2026-10-18. Base: origin/feat-cmux-next. Author: Claude Code agent for the Chief.

## 0. Short answer

**No, not end to end.** You can create a cloud machine and see it in the sidebar today.
The parts that are missing are listed here:

- The local Chief cannot start, prompt, watch or stop an agent on a cloud machine. Its
  `spawn` has no location and always uses the acpmux daemon on this Mac.
- `cloud_vms` is only a grant name. No tool implements it.
- Nothing meters VM time. Credits cover only Chief model tokens.
- Credit top-ups through Stripe work only in test mode.

The Cloud Chief (backend Durable Object) can already drive agents on Freestyle "hand"
sandboxes on staging, but those agents do not appear as sidebar workspaces.

Most of the building blocks exist. The work is mainly to connect them, not to build new
systems.

## 1. Inventory

Paths are relative to the repo root. "works" means the code, tests and config are in
place. I read the code; I did not run it end to end.

| Piece | Where | State |
|---|---|---|
| Freestyle SDK + driver (classic Cloud) | `web/services/vms/drivers/freestyle.ts` (`FreestyleProvider` :1088), `freestyle` 0.2.10 | works (production) |
| Freestyle driver (cmux-next Worker) | `backend/apps/api/src/cloud-driver.ts` (`FreestyleCloudDriver` :497), `cloud-do.ts`, `cloud-idle.ts`, `cloud-sweep.ts` | partial: dev only. `domains/cloud-plan.ts` is a stub, and production has no `CLOUD_FREESTYLE_SNAPSHOT` or `CLOUD_ALLOWED_TEAMS` |
| Freestyle keys | web `FREESTYLE_API_KEY`; Worker `CLOUD_FREESTYLE_API_KEY`, `HAND_FREESTYLE_API_KEY`, `FREESTYLE_API_KEY` (team VM) | works |
| cmux-next template image (cmux-tui = cmux + acpmux, cmux-tui-hook, claude, codex, opencode, coderouter, browser role) | `images/cmux-vm/inputs.lock.json`, `bake.ts` → `web/scripts/cmux-vm-image/bake.ts`, `smoke.ts`, `promote.ts`, `.github/workflows/cloud-vm-image-bake.yml` | partial: dev channel only (`channels/dev.json`, `cmuxnp-dev-vmimg-hostrun8`). Bake is manual dispatch only. The lock pins cmux-tui `bb19994` from 2026-10-11, not nightly |
| Classic devbox image | `web/scripts/build-devbox-freestyle.ts`, `web/services/vms/images/manifest.json` | works, classic product (Go cmux, not cmux-next) |
| Hand sandbox image (acpmux hand + claude + opencode, no codex, no cmux-tui session) | `backend/apps/api/scripts/bake-hand-sandbox.ts`, `cmuxnp-stg-hand-v4` | works on staging |
| Headless cmux-tui on Linux + remote link (Noise, `/v1/link`, resume lease, snapshots) | `cmux-tui/docs/remote.md`, `docs/cloud-cmux-tui-daemon.md`, `crates/cmux-remote` | works |
| Linux musl builds of cmux-tui / acpmux per tree, nightly | `.github/workflows/cmux-tui-build-package.yml`, `cmux-tui-artifacts.yml`, `cmux-tui-nightly.yml` | works |
| Mac app: create cloud machine, sidebar row, attach (WireGuard tunnel + `cmux-tui remote connect`) | `Packages/macOS/CmuxNext/Sources/CmuxNextCloud/API/CloudAPIClient.swift`, `CmuxNextApp/Cloud/CloudService.swift`, `CloudMachineLink.swift`, `CloudTunnelHub.swift`, `CmuxNextActions/Catalog/CloudActionCatalog.swift` | works against the classic web `/api/vm` |
| acpmux daemon (ACP JSON-RPC on a Unix socket + WebSocket `127.0.0.1:47811`, bearer tokens, `ssh://` / `wss://` peers) | `cmux-tui/crates/acpmux/` (`daemon.rs:934`, `peer.rs`, `server/conn_auth.rs`, `server/remote_guard.rs`) | works |
| acpmux hand (dials out, `fs.*`, `exec`, `agent.*`) + HandDO + permission levels | `cmux-tui/crates/acpmux/src/hand/`, `backend/apps/api/src/hand-*.ts`, `docs/chief-hands.md` | works on staging, off on production |
| Local Chief tools (`spawn`, `tell`, `profile`, `chiefs`) | `Native/OptChat/optchat-chief/src/mcp.rs:33-57`, `subagents.rs` (`MAX_LIVE=16` :53) | works, local only. No location parameter |
| Uncapped subagents | worktree `chief-unlimited-agents`, `subagents.rs` `live_limit()` from `OPTCHAT_MAX_LIVE_SUBAGENTS` | partial: not committed |
| `cloud_vms` Chief grant | `cmux-tui/crates/cmux-tui-core/src/chief_registry.rs:46`, `schemas/chief-profile/chiefs-tool.json:15` | missing: name only, no tool |
| Cloud Chief brain + `spawn` + `hands`/`agent` tools | `backend/apps/api/src/chief-brain/brain-do.ts`, `brain-spawn.ts` (`CHIEF_SPAWN_MAX`=4), `brain-hands.ts` | works on staging; production brains have no hands |
| Turn-end detection for the Chief | `cmux-chief/src/rules.rs` `turn_ended` (acpmux state Running/Waiting → Ready/Idle), `brain/children.rs`, `brain/spawns.rs` | works (acpmux events) |
| OSC 7501 program status | ghostty-next `program_status.zig`, `cmux-tui/crates/ghostty-vt/src/terminal/program_status.rs`, `cmux-tui-core/src/program_status.rs`, `cmux agents wait` | works for sidebar and tab state, and `cmux agents wait`. The Chief does **not** read it today |
| Durable Run API (Vercel, Postgres) | `web/services/runs/*`, `web/app/api/runs/*`, `web/services/vms/cloudVmRunAdapter.ts` | works in web; nothing in the Chief calls it |
| Credits ledger (reserve / settle / release, micro-dollars) | `backend/apps/api/src/usage-meter-do.ts`, `usage-credits.ts`, `credits.ts` | works, model tokens only |
| Credit top-up via Stripe Checkout (one-time payment) + webhook | `backend/apps/api/src/credits-checkout.ts`, `credits-routes.ts` (`/v1/hooks/stripe/credits`) | partial: test mode only, refused on production |
| VM-minute metering | `Budget.vm_minutes` (`backend/packages/protocol/src/automations.ts:142`) | missing: schema field only |
| Subscriptions (Go/Pro/Team/Max), checkout, portal, webhook | `web/services/billing/*`, `web/app/api/billing/*`, `web/app/api/stripe/webhook` | works (classic web) |
| Classic VM billing (included VM hours, Stack payment items) | `web/services/vms/goUsage.ts`, `billingGateway.ts`, `entitlements.ts` | works, classic product |
| Auth: Mac → web (Stack tokens), Mac → Worker (install identity + ES256/EdDSA) | `CmuxNextCloud/Auth/CloudAuth.swift`, `MacInstallIdentity.swift`, `backend/apps/api/src/auth.ts`, `link-token.ts` | works |
| Secrets in VM (`vm env`), file push, layouts, `vm agent --wait` | `docs/cloud-agent-primitives.md` | works in classic CLI; Mac-side verbs moved to `cmux cloud …` |
| `reload-cloud` | referenced in `plans/cmux-next/shell.md:72`, HQ script | missing in this repo |
| Fleet builds (`cmux-ci`) | `~/.local/bin/cmux-ci` | works (Mac builds, not related to cloud workspaces) |
| Open PRs on `main` lineage | #21028 Cloud Secrets / repo clone / onboarding, #21837 `cmux vm clean` | not merged, classic app |

**Important fact:** there are three cloud VM stacks: classic web (`web/`, Vercel), the
cmux-next Worker (`backend/`, CloudDO + hands), and `workers/cmux-vm`. This plan picks one.

## 2. Goals

1. One Freestyle template with cmux (headless cmux-tui), acpmux, claude, codex and opencode.
   It is rebuilt and versioned for each nightly.
2. A cloud workspace shows in the local sidebar like a local one: you open it, type in it,
   and it reconnects after sleep or a network change.
3. The local Chief and its subagents start, prompt, watch and stop cloud agents through the
   same API as local agents, with `location: "local" | "cloud"`.
4. Cloud use costs credits. The Chief can offer cloud. If the balance is too low, it gives a
   Stripe Checkout link and continues when the payment arrives.
5. Work continues when the laptop is closed. The Chief sees the result when it comes back.

## 3. Decision A: which control plane owns cloud workspaces

| Option | Good | Bad |
|---|---|---|
| **A1. cmux-next Worker (`backend/`, CloudDO + HandDO + UsageMeterDO)** | Credits ledger, Stripe top-up, hands, Cloud Chief and the cmux-next image are already here. Durable Objects give one strongly consistent owner per machine and per team. Staging auto-deploys from feat-cmux-next. | Production plan is a stub. VM metering must be added. The Mac app talks to the classic web API today. |
| A2. Classic web (`web/`, Vercel + Postgres) | Production today, mature (limits, idempotency, reaper, subscriptions). | Classic Go-era product. No credits ledger. Two products would bill cloud time two ways. |
| A3. `workers/cmux-vm` | Clean API. | Billing is a TODO and its tests were deleted. A third stack. |

**Recommendation: A1.** Point the CmuxNext Mac app at CloudDO for new cloud workspaces, and
keep classic `/api/vm` for classic users until they move. Do not add features to A2 or A3
for this work.

## 4. The template

There is no need for a new image. `images/cmux-vm` already installs cmux-tui (one binary
that is both `cmux` and `acpmux`), `cmux-tui-hook`, claude, codex, opencode, coderouter and
the browser role. It also boots `cmux host run`, which supervises the session daemon and
the acpmux daemon. What is missing is automation and channels.

Nightly pipeline (new workflow `cloud-template-nightly.yml`, runs after `cmux-tui-nightly.yml`):

1. `bun images/cmux-vm/pin-cmux-tui.ts --commit <nightly tree> --write`. This prototype is
   in this commit. It reads only files.cmux.com and updates the cmux-tui and cmux-tui-hook
   pins (url, sha256, size). It does not create a VM.
2. Bump the agent CLIs (claude, codex, opencode) to the latest versions that are at least
   7 days old (the same rule as `bun install --minimum-release-age`), with sha256 pins.
   This is a small extension of the same script.
3. Bake: `cloud-vm-image-bake.yml` with `keep_snapshot`. **This costs Freestyle money**
   (one builder VM for about 15 minutes, plus 2–5 smoke clones). Today it is manual by
   decision (2026-10-04). Running it each night needs your approval.
4. Smoke: `smoke.ts --agent-probe --expect-capabilities`, plus a new agent probe: start
   claude and codex through acpmux with a model-gateway run token, send one prompt, and
   expect `turn_end`.
5. Promote: `promote.ts --channel staging` automatically when the smoke passes; production
   by hand (or automatically after 24 h on staging with no failures).
6. Name: `cmuxnp-<env>-tmpl-<yyyymmdd>-<cmux-tui sha7>`. Keep the last 3 snapshots per
   channel and delete older ones by exact id (the rule `channels/dev.json` already follows).

A snapshot is a memory image. The boot path must create a fresh Noise identity and a fresh
acpmux token per machine. The devbox image already does this for the daemon; the smoke must
assert it for acpmux too.

Option to merge the hand image: make `bake-hand-sandbox.ts` obsolete by putting
`cmux-hand` (the acpmux binary, already in the tree) into the template. A Chief sandbox is
then a cloud workspace you can open, not a separate kind of machine. **Recommended.**

## 5. Decision B: how the local Chief drives a cloud agent

All three options end at the same place: the acpmux daemon inside the cloud machine.
Agent sessions live there, so they survive the Mac sleeping.

| Option | How | Good | Bad |
|---|---|---|---|
| **B1. acpmux peer over the machine link** | The local acpmux adds the cloud machine as a peer (`wss://`, `peerToken`), through the existing WireGuard tunnel or a stream on the cmux-tui Noise link. `subagents.rs` passes `host: <machine>` on session create; every other call is unchanged. | Same ACP protocol and events, so `turn_ended`, `tell`, attach and permission prompts work as for local agents. Lowest latency. No new server code. | Needs the Mac online to *send* prompts. Agents keep running when it is offline. The Chief catches up from acpmux events since its floor on reconnect. |
| B2. Through the Cloud API hand (HandDO `agent.*`) | The machine runs `cmux-hand`, which dials out. The local Chief calls the Cloud API, and HandDO relays to the in-VM acpmux. | No inbound port. The Cloud Chief already uses it. Works for a phone or a Chief with no Mac. | Every call goes through the Worker (extra hop and cost). A second event format to map onto `turn_ended`. Permission and approval rules differ from local. |
| B3. Durable Run API (web) | `/api/runs` with the cloud VM run adapter. | Durable, already dogfooded. | Classic web stack (against Decision A). Batch-shaped, not interactive. |

**Recommendation: B1 for the local Chief, B2 for the Cloud Chief, one runtime.** Both are
clients of the same in-VM acpmux, so a session started by one is visible to the other. This
gives "one API, location = local | cloud" at the acpmux layer, where the Chief already works.

### Chief API change

```jsonc
// spawn, per task (optchat-chief mcp.rs)
{ "task": "...", "cwd": "~/fun/cmux", "where": "local" | "cloud" | "auto",
  "machine": "optional existing machine id", "repo": "optional git url + ref" }
```

- `where: "cloud"` → `cloud.ensure_machine` (CloudDO create or reuse, idempotency key =
  chief turn id + task index) → `acpmux peer add` → session create on that host.
- `where: "auto"` (default stays `local`) → the Chief chooses cloud when the local live
  limit is reached, or when the task says "keep running when I close the laptop".
- `tell`, `stop` and watching are unchanged. They use the session id, and acpmux routes to
  the peer.
- A new `cloud` tool, gated by the existing `cloud_vms` grant: `quote`, `balance`,
  `machines`, `stop_machine`, `checkout`. This implements the grant that today is only a
  name.

### Turn-end detection

- **Agent sessions (claude, codex, opencode via ACP):** keep `rules::turn_ended` on acpmux
  state, and `turn_end` events. These are protocol events and travel unchanged over the
  peer link. This is the main signal.
- **Terminal agents (a TUI started in a cmux-tui terminal):** OSC 7501 is parsed by the
  in-VM cmux-tui and published as `extra.program_status` on the terminal. The remote link
  already carries terminal metadata to the Mac sidebar. Add a Chief watcher that subscribes
  to `program_status` on that terminal (local or remote, same RPC) and treats
  `working → idle` as a turn end. Today only the sidebar and `cmux agents wait` read it.
  Note: the `chief-unlimited-agents` worktree has no OSC 7501 terminal agent. It only has
  the cap change, so this watcher is new work.
- Both cases produce one `ChildEvent::TurnEnded { session, reason }` so the Chief logic
  does not depend on location or kind.

## 6. Cloud workspace in the sidebar

- **Create:** "New Cloud Workspace" (palette, sidebar `+`, CLI `cmux cloud new-workspace`,
  Chief `spawn where=cloud`) all call one `CloudWorkspaceCoordinator.create(spec)` → CloudDO.
- **Attach:** keep today's path: WireGuard tunnel enrolment, then `cmux-tui remote connect`
  to `ws://<vpc-ip>:1337/v1/link`, rendered through the Ghostty manual-IO surface. It has
  Noise auth against enrolled device keys, a 120 s resume lease and snapshot resync.
- **Fallback when UDP is blocked:** the iroh relay path (`web/services/relay`,
  `cmux-tui/crates/cmux-relay`). Choose it automatically after one failed tunnel handshake.
- **Latency:** local echo is not possible for a remote PTY. Choose the Freestyle region
  nearest the user at create, and show the RTT in the row's tooltip.
- **Reconnect:** within the lease, replay by cursor. After the lease, snapshot. After a
  daemon restart, show "machine restarted" (the generation changed). Never show a silently
  new shell.
- **Row state:** running / paused / waking / stopped / no credits, from CloudDO over the
  user wire socket. No polling.
- **Agent rows:** acpmux sessions on the machine appear under the machine's workspace,
  the same as local agent sessions. Cloud subagents that a Chief starts become real sidebar
  workspaces, grouped by topic like local ones.

## 7. Repo, credentials and secrets

- **Code:** `repo` in the spawn spec → in-VM `git clone` with a short-lived GitHub token.
  The token is a GitHub App installation token minted by the Worker per machine, per
  repo, valid 1 h, delivered over the link into `cmux env receive` (no token on a command
  line or in the image). If no repo is given, push the local working tree with
  `vm push` (chunked, hashed). Do not sync the whole home folder.
- **Push back:** the agent pushes a branch. It never force-pushes, as on the Mac.
- **Model access, two choices** (decision for you):
  - Model gateway run tokens (`ANTHROPIC_BASE_URL` → `/v1/model-gateway`, already built,
    charged to credits). Claude works today. Codex needs an OpenAI-compatible route
    through coderouter, which is not built.
  - The user's own Claude/Codex subscription login inside the VM (no credits for tokens,
    but a credential then lives on a machine we host).
- **Secrets:** `vm env set` (0600 on the persistent volume, delivered over the end-to-end
  link). Never bake a secret into the template. The bake already parks and wipes daemon
  state.
- **Hand key risk:** at level `full`, the hand's key can be read by programs it runs (see
  `docs/chief-hands.md`). Keep cloud sessions at `full` only inside the VM, and scope the
  hand key to that one machine.

## 8. Cost control and idle shutdown

- Freestyle bills while a VM runs. Paused VMs cost storage only.
- **Idle pause:** CloudDO already has `cloud-idle.ts` (activity reports). Rule: pause after
  15 min with no terminal input, no running acpmux turn and no attached client. A turn that
  is still running keeps the machine awake, up to a per-task cap (default 2 h, set in
  spawn).
- **Hard stops:** a machine-hours cap per day per team; pause when credits are exhausted
  (after a 5-minute grace and a notice to the Chief and the sidebar).
- **Wake:** opening the row, a Chief `tell`, or a hand request resumes the VM. Freestyle
  resume is a few seconds; the link resume lease covers it.
- **Sizes:** default to the smallest ladder size. Resize is grow-only, so the Chief asks
  before it grows a machine.
- **Sweep:** the existing hourly sweep removes leaked VMs by exact id and tag.

## 9. Billing

### Decision C: billing model

| Option | Good | Bad |
|---|---|---|
| **C1. Prepaid credits (backend ledger) for VM-minutes and model tokens, top-up by Stripe Checkout `mode: payment`** | The ledger, holds, settle, and the checkout and webhook code already exist. One balance for everything in the cloud. A natural "you have no credits, pay here" flow. No surprise bills. | Users must top up. Need auto-recharge later. |
| C2. Subscription with included VM hours (classic Go plan model) | Exists in web. Predictable revenue. | Does not fit "pay to continue now". Two billing systems for cmux-next. |
| C3. Postpaid Stripe usage meters | `billing-usage-sync.ts` exists. | Needs a card on file first, and has bad-debt risk. The Chief cannot say "pay this link to continue". |

**Recommendation: C1.** Plans (Pro/Max) grant a monthly amount of credits into the same
ledger (the `billing-catalog.ts` included amounts become credit grants).

### Metering

- On create or resume, CloudDO reserves 10 minutes × the size price (`creditReserve`).
- Each minute, the CloudDO alarm settles the minute that passed and extends the hold.
  Runtime intervals come from Freestyle state, not from the guest.
- On pause or stop, settle the partial minute and release the rest.
- The price is Freestyle cost × `CLOUD_CREDITS_MARGIN`, a new var like `CHIEF_CREDITS_MARGIN`.
- Model tokens keep today's gateway metering. One ledger, two meters: `vm.minutes.<size>`
  and `model.spend_usd`.
- Idempotency: the settle key is `(machine, minute index)`, so an alarm retry never charges
  twice.

### The Chief offers cloud

1. The Chief sees a reason to use cloud: live limit reached, long task, a task the user
   wants to keep running, or the user asks.
2. It calls `cloud.quote` → `{price_per_minute, balance, minutes_left}`.
3. If the balance covers at least 30 minutes, it says so and starts (or asks first, by a
   setting: "always ask" / "auto under N USD").
4. If not, it calls `cloud.checkout {amount}`. The Worker creates a Stripe Checkout Session
   server-side (`credits-checkout.ts`) with `client_reference_id = team`, metadata
   `{team, chief_turn}`, and returns the URL. The Chief posts it as a link card.
5. The Stripe webhook `checkout.session.completed` → `/v1/hooks/stripe/credits` → grant
   once per session id (already idempotent) → a `credits-granted {team, amount, chief_turn}`
   event on the user wire. The Chief wakes on it and continues the queued cloud spawn.
   Also handle `checkout.session.expired` (the Chief says the link expired and offers a new
   one) and `charge.refunded` (negative entry).
6. Amounts: 10 / 25 / 100 USD presets. Never let the model choose an arbitrary amount
   without a cap.

To go live, someone with Stripe access must create the live product and prices, set
`STRIPE_CREDITS_KEY` and `STRIPE_CREDITS_WEBHOOK_SECRET` for production, and remove the
test-only refusal in `credits-checkout.ts:23-31`. I did none of this.

## 10. Failure modes

| Failure | Behaviour |
|---|---|
| Freestyle create fails or times out | CloudDO ledger retries with the same idempotency key; after 3 tries, release the hold and tell the Chief `cloud_unavailable`. The Chief falls back to local if allowed. |
| Mac sleeps or the network changes | Sessions keep running in the VM. The link resumes within 120 s, else snapshot. The Chief reads acpmux events since its floor on reconnect. |
| VM paused for idle while the Chief waits | `tell` wakes it. A running turn blocks idle pause, so a pause means no turn was running. |
| Credits run out during a turn | Notice to the Chief at 5 minutes left, pause at 0 after the grace. Sessions survive the pause and resume after a top-up. |
| Webhook delayed or lost | The return page also grants (already in the code). A reconcile job reads Checkout Sessions of the last 24 h. |
| Daemon restart in the VM | Generation change is reported; acpmux sessions restore from its journal or are marked lost. Never a silent new shell. |
| Snapshot built with a shared identity | Smoke asserts unique Noise and acpmux identities across 2 clones; promotion refuses otherwise. |
| Leaked VMs | Hourly sweep by tag + exact id; daily cost alert. |
| Bad nightly template | Staging-only auto promotion; one-command rollback (`promote.ts --rollback`). Running VMs keep their image. |
| Stolen hand or peer token | Tokens are per machine, rotated on resume; `acpmux web --rotate-token`; revoke on machine delete. |

## 11. Milestones

Estimates are for one agent-team lane with review, wall-clock.

| # | Milestone | Content | Estimate |
|---|---|---|---|
| M0 | Decisions | Your answers to the decisions in REPORT.md | — |
| M1 | Nightly template | `pin-cmux-tui.ts` (prototype done), agent CLI bump, nightly workflow, staging and production channels, identity smoke, hand binary in the template | 2–3 days |
| M2 | cmux-next cloud workspaces on CloudDO | Real `cloud-plan.ts`, production snapshot var, Mac app create and attach against CloudDO, sidebar row states | 4–6 days |
| M3 | VM-minute metering | Reserve/settle per minute in CloudDO, `vm.minutes` meter, credits-exhausted pause, notices | 2–3 days |
| M4 | Chief `where: cloud` | `spawn` location, acpmux peer to the machine, `cloud` tool behind `cloud_vms`, OSC 7501 watcher, one TurnEnded event | 4–5 days |
| M5 | Checkout flow | Live Stripe product/prices (by you), checkout presets, `credits-granted` wake, expired/refund handling, reconcile | 2–3 days |
| M6 | Repo and secrets | GitHub App token per machine, `repo` in spawn, `vm push` fallback, model access choice | 3–4 days |
| M7 | Hardening | Failure-mode tests (dogfood journey: spawn cloud → close lid → reopen → result), cost alerts, docs, localization of new UI strings | 3–4 days |

Total: about 4–5 weeks of lane time. M1, M3 and M5 can run in parallel with M2.

## 12. What this commit contains

- `PLAN.md` (this file) and `REPORT.md`.
- `images/cmux-vm/pin-cmux-tui.ts`: dry-run by default. It reads files.cmux.com only,
  creates no VM, and needs no key. With `--write` it updates the two pins in place and
  checks the result with the lock validator. I tested it with `--latest` on a copy of the
  lock. I did **not** change the checked-in lock, because a new pin needs a bake and a smoke
  first.
