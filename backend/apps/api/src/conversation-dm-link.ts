import { tablesFor, type RowReader, type SqlStore } from "@cmux/ownership"
import { conversation } from "@cmux/home-core"

export type DmLink = { peer: string | null; consented: boolean } | null

/**
 * The reach facts a DM gives `adder` about `target` (home-reach.ts). `peer` is the target's name
 * while both are current human participants; `consented` holds when the pair gave consent (16.8):
 * both have sent a message here, or the DM came from an invite one of them sent and the other
 * accepted (16.4). Authorship comes from the private `consent` markers (home-core consent.ts),
 * which retention never deletes, so an old DM stays connected after its messages expire. A DM
 * from before the markers falls back to its `msgkey` rows (keyed `<author>:<client_msg_id>`, an
 * index range read): any commit that deletes such a row writes the author's marker in the same
 * commit, so the fallback is only read while the rows it reads still exist.
 */
export const dmLinkOf = (state: conversation.ConversationHead, rows: RowReader & { scan<T>(tbl: string, limit?: number): Array<{ row: T }> }, sql: Pick<SqlStore, "exec">, adder: string, target: string): DmLink => {
  if (state.kind !== "dm") return null
  const current = (id: string) => state.participants.find((p) => p.id === id && p.kind === "human" && p.left_at === undefined)
  if (!current(adder)) return null
  const peer = current(target)
  if (!peer) return { peer: null, consented: false }
  const table = tablesFor().rows
  const authored = (who: string) =>
    conversation.hasConsentMarker(rows, who) ||
    sql.exec<{ one: number }>(`SELECT 1 AS one FROM ${table} WHERE tbl = ? AND k >= ? AND k < ? LIMIT 1`, conversation.TABLE_MSGKEY, `${who}:`, `${who};`).length > 0
  const pair = new Set([adder, target])
  const invited = () =>
    [...(state.invites ?? []), ...rows.scan<conversation.Invite>(conversation.TABLE_INV, 1000).map((r) => r.row)].some(
      (i) => i.status === "accepted" && i.accepted_by !== undefined && i.invited_by !== i.accepted_by && pair.has(i.invited_by) && pair.has(i.accepted_by)
    )
  return { peer: peer.display_name, consented: (authored(adder) && authored(target)) || invited() }
}
