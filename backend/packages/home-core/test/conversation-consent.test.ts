import { describe, expect, it } from "vitest"
import {
  conversationDomain,
  consentMarkerWrites,
  dmConversationId,
  hasConsentMarker,
  PRIVATE_TABLES,
  TABLE_CONSENT,
  TABLE_MSGKEY,
  type ConversationParams,
  type ConversationState,
  type HumanReach,
  type Principal,
  type RowWrite
} from "../src/conversation/index.ts"
import { DomainHost, human } from "./support/harness.ts"
import { ALICE, BOB } from "./support/cloud.ts"

/**
 * Consent markers (home-messaging.md 16.8 and section 10): a DM's author gets one private
 * `consent` row at their first message there. Retention deletes `msg` and `msgkey` rows but never
 * `consent` rows, so a pair that both wrote stays connected after their messages expire. A DM
 * from before the markers has `msgkey` rows only: any commit that writes or deletes an author's
 * `msgkey` row in a DM adds that author's marker in the same commit, so a retention delete can
 * never remove the last proof without leaving a marker.
 */
const session = (user: string, name: string, home_reach?: ReadonlyArray<HumanReach>): Principal => ({
  identity: `${user}:s`,
  user,
  kind: "session",
  display_name: name,
  ...(home_reach ? { home_reach } : {})
})
const reach = (user: string): HumanReach => ({ user, display_name: "Bob", shared_team: true, connected: false, allow_requests_from: "anyone" })
const DM = dmConversationId(ALICE, BOB)
const openDm = () => {
  const h = new DomainHost<ConversationState, ConversationParams>(conversationDomain)
  expect(h.run(session(ALICE, "Alice", [reach(BOB)]), "dm.open", { id: DM, participants: [human(ALICE, "Alice"), human(BOB, BOB)] }, "d1")).toMatchObject({ ok: true })
  return h
}
const send = (h: DomainHost<ConversationState, ConversationParams>, user: string, key: string) =>
  h.run(session(user, user === ALICE ? "Alice" : "Bob"), "message.send", { client_msg_id: key, parts: [{ type: "text", text: key }] }, key)
const consentWrites = (r: { ok: boolean; writes?: ReadonlyArray<RowWrite> }) => (r.ok ? (r.writes ?? []) : []).filter((w) => w.table === TABLE_CONSENT)

describe("DM consent markers", () => {
  it("an author's first message in a DM writes their marker once; the table is private", () => {
    const h = openDm()
    const first = send(h, ALICE, "a1")
    expect(consentWrites(first)).toEqual([{ table: TABLE_CONSENT, op: "upsert", key: ALICE, n: null, row: { at: expect.any(String) } }])
    expect(consentWrites(send(h, ALICE, "a2"))).toEqual([])
    expect(hasConsentMarker(h.rows, ALICE)).toBe(true)
    expect(hasConsentMarker(h.rows, BOB)).toBe(false)
    expect(consentWrites(send(h, BOB, "b1")).map((w) => w.key)).toEqual([BOB])
    expect(PRIVATE_TABLES).toContain(TABLE_CONSENT)
  })

  it("markers survive the deletion of every message row", () => {
    const h = openDm()
    send(h, ALICE, "a1")
    send(h, BOB, "b1")
    // Retention (or any purge) removes the messages and their keys, never the markers.
    h.rows.apply([
      { table: "msg", op: "delete", key: (h.rows.all<{ id: string }>("msg")[0] as { id: string }).id },
      { table: TABLE_MSGKEY, op: "delete", key: `${ALICE}:a1` },
      { table: TABLE_MSGKEY, op: "delete", key: `${BOB}:b1` }
    ])
    expect(hasConsentMarker(h.rows, ALICE)).toBe(true)
    expect(hasConsentMarker(h.rows, BOB)).toBe(true)
  })

  it("a commit that deletes a pre-marker author's msgkey row in a DM adds the marker in the same commit", () => {
    const h = openDm()
    // A DM from before the markers: msgkey rows, no consent rows.
    h.rows.apply([{ table: TABLE_MSGKEY, op: "upsert", key: `${ALICE}:old`, n: null, row: { message_id: "msg_old" } }])
    const deletes: Array<RowWrite> = [{ table: TABLE_MSGKEY, op: "delete", key: `${ALICE}:old` }]
    const added = consentMarkerWrites(h.state, deletes, h.rows, "2026-10-01T12:00:00.000Z")
    expect(added).toEqual([{ table: TABLE_CONSENT, op: "upsert", key: ALICE, n: null, row: { at: "2026-10-01T12:00:00.000Z" } }])
    // An author who already has a marker gets none; a group never gets markers.
    h.rows.apply(added)
    expect(consentMarkerWrites(h.state, deletes, h.rows, "2026-10-01T12:00:00.000Z")).toEqual([])
    expect(consentMarkerWrites(h.state ? { ...h.state, kind: "group" } : null, [{ table: TABLE_MSGKEY, op: "delete", key: `${BOB}:x` }], h.rows, "2026-10-01T12:00:00.000Z")).toEqual([])
  })

  it("a group message writes no marker", () => {
    const h = new DomainHost<ConversationState, ConversationParams>(conversationDomain)
    expect(h.run(session(ALICE, "Alice"), "conversation.create", { id: "conv_G", kind: "group", title: "Plans", participants: [human(ALICE, "Alice")] }, "c1")).toMatchObject({ ok: true })
    expect(consentWrites(send(h, ALICE, "g1"))).toEqual([])
  })
})
