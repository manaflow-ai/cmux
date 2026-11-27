import { WorkerEntrypoint } from "cloudflare:workers"
import type { Env } from "./env.ts"
import { isOwnSlackMessage, slackEnabled, validSlackInbound, type SlackInbound } from "./chief-slack.ts"
import { brainName } from "./chief-brain/brain-do.ts"
import { declared } from "./do-stub.ts"

/** Trusted service-binding RPC only. Slack's signature and install ownership are checked by cmux-platform. */
export class PlatformChief extends WorkerEntrypoint<Env> {
  async slackInbound(inbound: SlackInbound) {
    if (!slackEnabled(this.env)) return { ok: false as const, code: "slack.disabled" }
    if (!validSlackInbound(inbound)) return { ok: false as const, code: "validation.invalid" }
    if (isOwnSlackMessage(inbound)) return { ok: true as const, ignored: true as const, queued: false }
    const user = declared(this.env.USER_DO.get(this.env.USER_DO.idFromName(inbound.ownerUserId)))
    const r = await user.readOp(inbound.ownerUserId, { identity: `session:${inbound.ownerUserId}`, kind: "session", user: inbound.ownerUserId }, "chief.list", {})
    if (!r.ok) return { ok: false as const, code: r.code }
    const chiefs = (r.value as { chiefs?: Array<{ id: string; main_conversation: string | null; is_default: boolean; archived_at: string | null; brain_place?: unknown }> }).chiefs ?? []
    const chief = chiefs.find((c) => c.is_default && c.archived_at === null)
    if (!chief?.main_conversation) return { ok: false as const, code: "chief.not_found" }
    if (chief.brain_place) return { ok: false as const, code: "chief.placed" }
    const brain = this.env.CHIEF_BRAIN_DO.get(this.env.CHIEF_BRAIN_DO.idFromName(brainName(chief.id, chief.main_conversation)))
    return brain.slackInbound({ agent: chief.id, conversation: chief.main_conversation, inbound })
  }
}
