# Report: cloud orchestration (2026-10-18)

## Can we orchestrate sessions from the cloud today?

**No.** You can make a cloud machine and see it in the sidebar. The local Chief cannot
start, prompt, watch or stop an agent on it: `spawn` has no location, and `cloud_vms` is
only a name. The Cloud Chief can drive agents on Freestyle "hand" sandboxes, but only on
staging, and those agents do not show in the sidebar. Nothing meters VM time. Credit
top-ups work only in Stripe test mode.

## Inventory

| Piece | Where | State |
|---|---|---|
| Template image with cmux-tui (cmux + acpmux), claude, codex, opencode | `images/cmux-vm/` | partial: dev channel only, manual bake, pin from 2026-10-11 |
| Freestyle driver, cmux-next Worker | `backend/apps/api/src/cloud-do.ts`, `cloud-driver.ts` | partial: dev only, production plan is a stub |
| Freestyle driver, classic web | `web/services/vms/drivers/freestyle.ts` | works (classic product) |
| Hand sandbox image + acpmux hand + HandDO | `backend/apps/api/scripts/bake-hand-sandbox.ts`, `cmux-tui/crates/acpmux/src/hand/` | works on staging, off on production |
| Headless cmux-tui + remote link (Noise, resume, snapshots) | `cmux-tui/docs/remote.md` | works |
| Mac: create machine, sidebar row, attach | `CmuxNextCloud/`, `CmuxNextApp/Cloud/` | works against classic `/api/vm` |
| acpmux over network (WebSocket, tokens, peers) | `cmux-tui/crates/acpmux/` | works |
| Local Chief `spawn`/`tell` | `Native/OptChat/optchat-chief/src/subagents.rs` | works, local only, cap 16 |
| `cloud_vms` tool | `chief_registry.rs:46` | missing (name only) |
| Cloud Chief + `hands`/`agent` tools | `backend/apps/api/src/chief-brain/` | works on staging |
| Chief turn-end detection | `cmux-chief/src/rules.rs` (acpmux state) | works |
| OSC 7501 | `program_status.rs`, `cmux agents wait` | works for sidebar; the Chief does not read it |
| Credits ledger | `backend/apps/api/src/usage-credits.ts` | works, model tokens only |
| Stripe Checkout credit top-up + webhook | `backend/apps/api/src/credits-checkout.ts` | partial: test mode only |
| VM-minute metering | `Budget.vm_minutes` | missing |
| Subscriptions (Go/Pro/Team/Max) | `web/services/billing/` | works (classic) |
| `reload-cloud` | not in this repo | missing |

The full table is in PLAN.md section 1.

## Recommended architecture

1. One control plane: the cmux-next Worker (`backend/`: CloudDO, HandDO, UsageMeterDO). Do not extend classic web or `workers/cmux-vm` for this.
2. One template: `images/cmux-vm`, re-pinned to each nightly cmux-tui, baked, smoked, auto-promoted to staging, promoted to production by hand.
3. Put `cmux-hand` in the template, so a Chief sandbox is a normal cloud workspace.
4. Agents live in the in-VM acpmux, so they survive a closed laptop.
5. The local Chief reaches them as an acpmux peer over the machine link: `spawn {where: local|cloud|auto}`. Everything else stays the same API.
6. The Cloud Chief reaches the same acpmux through the hand (dial-out, no inbound port).
7. Turn end: acpmux `turn_end` for ACP agents, OSC 7501 `program_status` for terminal agents. Both become one `TurnEnded` event.
8. Sidebar: today's WireGuard + `cmux-tui remote connect` path, iroh relay as fallback. Row states come from CloudDO over the user wire socket.
9. Billing: prepaid credits for VM-minutes (reserve, settle per minute, idempotent) and tokens. Plans grant monthly credits.
10. No credits: the Chief calls `cloud.checkout`, posts the Stripe Checkout link, wakes on the `credits-granted` webhook event, and continues.

## Decisions for you

- Cloud control plane for cmux-next: reply `backend Worker (recommended)` or `classic web /api/vm`.
- How the local Chief drives cloud agents: reply `acpmux peer link, hand only for the Cloud Chief (recommended)` or `everything through the Cloud API hand`.
- Billing model: reply `prepaid credits per VM-minute with Stripe Checkout top-ups (recommended)` or `subscription with included VM hours` or `postpaid Stripe usage meters`.
- Nightly template bake costs Freestyle money (about one builder VM for 15 minutes plus 2 to 5 smoke clones per night). Today bakes are manual by decision. Reply `bake each nightly automatically` or `bake by hand only`.
- Model access in cloud VMs: reply `model gateway with credits (Claude works now, Codex needs a new route)` or `user's own Claude/Codex login in the VM`.
- Merge the hand sandbox image into the template: reply `merge (recommended)` or `keep two images`.
- When the Chief starts paid cloud work: reply `always ask first` or `start without asking under N USD (give N)`.
- Going live with Stripe needs your action: create the live credits product and prices, and set `STRIPE_CREDITS_KEY` and `STRIPE_CREDITS_WEBHOOK_SECRET` on production. Reply `I will do it` or `give me the exact steps`.

## Things I did not do, or did with less effort

- I did not run any bake, smoke or end-to-end test. I spent no money, made no Freestyle VM, and made no Stripe object. Statuses come from reading code and config.
- I did not update the checked-in lock with the new cmux-tui pin. The pin must be baked and smoked first.
- I did not measure the latency, cost or resume time numbers in the plan. They are estimates.
- The effort estimates in PLAN.md are rough.
- I found no OSC 7501 terminal agent in `chief-unlimited-agents`. That worktree has only the uncommitted subagent-cap change. The OSC 7501 watcher in the plan is new work.
- The `latest` cmux-tui build (6dc229ca) has a much smaller binary (35 MB) than the pinned one (88 MB). I did not find out why. Check this before you pin it.

## Commits

- `d8848c6b778`: PLAN.md and `images/cmux-vm/pin-cmux-tui.ts`
- `c77b58ee93e`: this report (this line was corrected in the next commit after the rebase).
