import type { Domain, EventFrame, OwnerEngine, OwnerFrame, Principal } from "@cmux/ownership"
import { conversation, invites } from "@cmux/home-core"

/** An invite still waiting for its recipient (pending, or waiting for approval). */
const isOpen = (i: conversation.Invite) => i.status === "pending" || i.status === "pending_approval"
import type { Env } from "./env.ts"
import { OwnerDO, type ReadResult } from "./owner-do.ts"
import { publicActor } from "./public-actor.ts"

type Head = conversation.ConversationState
const MAX_HISTORY_PAGE = 200

/** First word of a display name, for the public invite card (never a full name or an address). */
const firstName = (name: string | undefined): string | null => {
  const first = (name ?? "").trim().split(/\s+/)[0] ?? ""
  return first.length > 0 && first.length <= 40 && !first.includes("@") ? first : null
}

export type InvitePreviewResult =
  | { readonly state: "ok"; readonly inviter: string; readonly kind: "dm" | "group"; readonly title?: string }
  | { readonly state: "invalid" | "expired" }

/**
 * ConversationDO, one per conversation (home-messaging.md section 3): head, participants,
 * messages, reactions, edits, read cursors and invites, run by lane 15's pure domain in row
 * mode. Token hashes and accept proofs stay here (conversationRedact, private `invhash`).
 */
export class ConversationDO extends OwnerDO<Head> {
  constructor(ctx: DurableObjectState, env: Env) {
    const domain = conversation.makeConversationDomain({
      // The caller's verified address ids (HMAC with HOME_ADDRESS_KEY), for binding an email invite on accept.
      addressIdsFor: (p) => {
        if (p.email_verified !== true || !p.email || !env.HOME_ADDRESS_KEY) return []
        const address = invites.normalizeEmail(p.email)
        return invites.isAddress(address) ? [invites.addressId(env.HOME_ADDRESS_KEY, address)] : []
      }
    })
    super(ctx, env, domain as Domain<Head>, "conv", publicActor, {
      rowMode: { snapshotTable: conversation.TABLE_MSG, snapshotTail: 50 },
      redact: { ...conversation.conversationRedact, privateTables: conversation.PRIVATE_TABLES }
    })
  }

  private member(state: Head, principal: Principal) {
    const actor = conversation.actorOf(principal)
    return state && actor ? state.participants.find((p) => p.id === actor && p.left_at === undefined) : undefined
  }

  protected maySubscribe(state: Head, principal: Principal): boolean {
    return this.member(state, principal) !== undefined
  }

  /** The lowest message seq a member may see (history_visible: since_join hides older ones). */
  private floor(state: Head, me: { joined_seq?: number }): number {
    return state?.settings?.history_visible === "since_join" ? (me.joined_seq ?? 0) : 0
  }

  /**
   * Events reach current members only, and never carry a message row older than the member's
   * floor. A refused event becomes a filtered snapshot for that socket (OwnerDO.broadcast).
   */
  protected mayReceive(state: Head, event: EventFrame, principal: Principal): boolean {
    const me = this.member(state, principal)
    if (!me) return false
    const floor = this.floor(state, me)
    if (floor === 0) return true
    return !(event.effects?.writes ?? []).some((w) => w.table === conversation.TABLE_MSG && w.op === "upsert" && ((w.row as { seq?: number }).seq ?? 0) <= floor)
  }

  /** Snapshot tail rows honor the member's floor too. */
  protected subscriberSnapshot(snap: ReturnType<OwnerEngine<Head>["snapshot"]>, principal: Principal): unknown {
    const base = super.subscriberSnapshot(snap, principal) as typeof snap
    const state = snap.state as Head
    const me = state ? this.member(state, principal) : undefined
    if (!base.rows || !me) return base
    const floor = this.floor(state, me)
    return floor === 0 ? base : { ...base, rows: { ...base.rows, rows: base.rows.rows.filter((r) => ((r.row as { seq?: number }).seq ?? 0) > floor) } }
  }

  /** A participant who is removed or leaves loses its sockets at once (no later events). */
  protected afterOp(_principal: Principal, _op: string, _frames: ReadonlyArray<OwnerFrame>): void {
    const state = this.boundEngine?.currentState
    if (state) this.closeSockets((p) => this.member(state, p) === undefined, "not a participant")
  }

  /** conversation.history {before_seq?, limit?}: older messages, honoring history_visible. */
  protected read(state: Head, op: string, params: unknown, principal: Principal): ReadResult {
    const me = state ? this.member(state, principal) : undefined
    if (!state || !me) return { ok: false, code: "auth.forbidden", message: "not a participant" }
    if (op !== "conversation.history") return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
    const q = (params ?? {}) as { before_seq?: unknown; limit?: unknown }
    const limit = typeof q.limit === "number" && q.limit > 0 ? Math.min(q.limit, MAX_HISTORY_PAGE) : 50
    const before = typeof q.before_seq === "number" ? q.before_seq : undefined
    const floor = this.floor(state, me)
    const engine = this.boundEngine!
    const rows = engine.rows.range<conversation.Message>(conversation.TABLE_MSG, { ...(before === undefined ? {} : { before }), after: floor - 1, limit, desc: true })
    return { ok: true, value: { messages: rows.reverse().map((r) => r.row), has_more: rows.length === limit }, revision: "" }
  }

  /**
   * Anonymous, by link code: the inviter's first name for the Open Graph card. Answers only
   * while an invite is open, and never for a user-to-user DM (a DM answers only while its
   * peer is still the invited address).
   */
  async card(entity: string): Promise<{ first_name: string; avatar_url: null } | null> {
    const state = this.existingState(entity)
    const open = state?.invites?.find((i) => isOpen(i))
    if (!state || !open) return null
    if (state.kind === "dm" && !state.participants.some((p) => p.id === open.address && p.left_at === undefined)) return null
    const inviter = state.participants.find((p) => p.id === open.invited_by)
    const name = firstName(inviter?.display_name)
    return name ? { first_name: name, avatar_url: null } : null
  }

  /** Anonymous, by secret: who invited the holder. The secret is hashed twice, as the domain stores it. */
  async invitePreview(entity: string, secret: string): Promise<InvitePreviewResult> {
    const state = this.existingState(entity)
    if (!state) return { state: "invalid" }
    const tokenHash = invites.hashInviteSecret(invites.hashInviteSecret(secret))
    const ref = this.boundEngine!.rows.get<{ invite_id: string }>(conversation.TABLE_INVHASH, tokenHash)?.row
    const invite = ref ? this.boundEngine!.rows.get<conversation.Invite>(conversation.TABLE_INV, ref.invite_id)?.row : undefined
    if (!invite) return { state: "invalid" }
    if (!isOpen(invite) || Date.parse(invite.expires_at) <= Date.now()) return { state: "expired" }
    const inviter = state.participants.find((p) => p.id === invite.invited_by)
    return {
      state: "ok",
      inviter: firstName(inviter?.display_name) ?? "Someone",
      kind: state.kind === "dm" ? "dm" : "group",
      ...(state.kind === "group" && state.title ? { title: state.title } : {})
    }
  }

  /** State of an object that already serves this conversation; never creates storage for unknown ids. */
  private existingState(entity: string): Head | undefined {
    const row = this.sqlStore.exec<{ entity: string }>(`SELECT entity FROM do_entity WHERE id = 1`)[0]
    if (!row || row.entity !== entity) return undefined
    return this.bind(entity).currentState ?? undefined
  }
}
