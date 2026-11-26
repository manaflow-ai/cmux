import { WorkerEntrypoint } from "cloudflare:workers"
import type { RawEnv } from "./env.ts"
import { BASE_SPACE, spacedEnv } from "./build-space.ts"
import { isOwnSlackMessage, slackEnabled, slackMayAct, validSlackInbound, type SlackInbound } from "./chief-slack.ts"
import { brainName } from "./chief-brain/brain-do.ts"
import { declared } from "./do-stub.ts"

/** Trusted service-binding RPC only. Slack's signature and install ownership are checked by cmux-platform. */
export class PlatformChief extends WorkerEntrypoint<RawEnv> {
  async slackInbound(inbound: SlackInbound) {
    // Slack reaches nightly and stable's Chiefs only: a service-binding call carries no build space.
    const env = spacedEnv(this.env, BASE_SPACE)
    if (!slackEnabled(env)) return { ok: false as const, code: "slack.disabled" }
    if (!validSlackInbound(inbound)) return { ok: false as const, code: "validation.invalid" }
    if (isOwnSlackMessage(inbound)) return { ok: true as const, ignored: true as const, queued: false }
    const user = declared(env.USER_DO.get(env.USER_DO.idFromName(inbound.ownerUserId)))
    const r = await user.readOp(inbound.ownerUserId, { identity: `session:${inbound.ownerUserId}`, kind: "session", user: inbound.ownerUserId }, "chief.list", {})
    if (!r.ok) return { ok: false as const, code: r.code }
    const chiefs = (r.value as { chiefs?: Array<{ id: string; main_conversation: string | null; is_default: boolean; archived_at: string | null; brain_place?: unknown }> }).chiefs ?? []
    const chief = chiefs.find((c) => c.is_default && c.archived_at === null)
    if (!chief?.main_conversation) return { ok: false as const, code: "chief.not_found" }
    if (chief.brain_place) return { ok: false as const, code: "chief.placed" }
    const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(chief.id, chief.main_conversation)))
    // The persisted isOwner is what authorizes effects (effect-policy.ts): a channel without `run` keeps even the
    // owner's Slack messages to answers.
    return brain.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound: { ...inbound, isOwner: slackMayAct(inbound) } })
  }
}
