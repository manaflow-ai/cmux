import type { RowWrite } from "./engine-types.ts"
import type { Invite } from "./types.ts"

/** Row tables of the ConversationDO domain (domain.ts documents each one). */
export const TABLE_MSG = "msg"
export const TABLE_MSGKEY = "msgkey"
export const TABLE_INV = "inv"
export const TABLE_INVHASH = "invhash"
/** Per-user unread and mention counts (key = user id), kept by the owner for inbox bumps; private. */
export const TABLE_UNREAD = "unread"

export const msgKey = (author: string, clientMsgId: string) => `${author}:${clientMsgId}`

/** Row writes for invites that are new or changed between two invite lists. */
export const inviteWrites = (before: ReadonlyArray<Invite>, after: ReadonlyArray<Invite>): Array<RowWrite> => {
  const writes: Array<RowWrite> = []
  for (const invite of after) {
    const old = before.find((candidate) => candidate.id === invite.id)
    if (old && JSON.stringify(old) === JSON.stringify(invite)) continue
    writes.push({ table: TABLE_INV, op: "upsert", key: invite.id, n: null, row: invite })
    if (!old) writes.push({ table: TABLE_INVHASH, op: "upsert", key: invite.token_hash, n: null, row: { invite_id: invite.id } })
  }
  return writes
}
