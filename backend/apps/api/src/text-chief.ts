import type { OwnerFrame, Principal, SqlStore } from "@cmux/ownership"
import { address, invites } from "@cmux/home-core"
import type { Env } from "./env.ts"
import type { Fetch } from "./home-send.ts"
import type { SendblueMessage } from "./home-text.ts"
import { declared } from "./do-stub.ts"

/**
 * Texting Chief (home-messaging.md section 19; Lawrence 2026-11-02): one shared SendBlue line, each
 * inbound text routed by its sender's number to that person's primary Chief, the Chief's reply sent
 * back as a text. The AddressDO of the sender's number runs this (it holds the only copy of the
 * number); the rules are home-core `address/text-chief.ts`.
 *
 * Senders: the in-app phone link (`address.text_link`, when bound and not expired) or the
 * TEXT_CHIEF_PEOPLE secret. Anyone else gets UNKNOWN_SENDER_TEXT once per 30 days and nothing else.
 * The webhook secret is shared, not a signature (SendBlue has no body signing: `rawBodySigningAvailable`
 * is false on the account), so the route acts only on SendBlue's own record of the message.
 */

/** Fail-closed switch: only "on" reads and answers texts to Chief. */
export const textChiefOn = (env: Env) => env.TEXT_CHIEF === "on"

const UNKNOWN_REPLY_EVERY_MS = 30 * 24 * 3_600_000
/** A Chief's reply goes out as a text while the person's last text is this recent and they have not written in the app since. */
export const BRIDGE_MS = 6 * 3_600_000
/** Chiefs that answered in the thread this recently count as "in play" (their replies carry their name). */
const IN_PLAY_MS = 24 * 3_600_000
const TYPING_EVERY_MS = 8_000

interface ChiefRecord {
  readonly id: string
  readonly display_name: string
  readonly is_default: boolean
  readonly main_conversation?: string | null
  readonly archived_at: string | null
  readonly rev: number
}

/** What a conversation keeps to send its Chief's replies back as texts (no raw number: the AddressDO id). */
export interface TextBridge {
  readonly address: string
  readonly until: number
}

/** The line a reply goes out on, and the account's primary Chief when the text came in. */
export interface ThreadMemo {
  readonly line: string
  readonly owner: string
  readonly primary: string
  readonly service: string
}

export interface TextChiefDeps {
  readonly env: Env
  readonly sql: SqlStore
  readonly fetcher: Fetch
  readonly now: number
  /** The raw number this AddressDO holds. */
  readonly phone: string
  /** This AddressDO's id. */
  readonly address: string
  /** The number's in-app link binding, if any. */
  readonly binding: { readonly user: string; readonly expires_at: number } | null
}

const ownerPrincipal = (user: string, addr: string): Principal => ({ identity: `text:${addr}`, kind: "session", user })
const userStub = (env: Env, user: string) => declared(env.USER_DO.get(env.USER_DO.idFromName(user)))
const conversationStub = (env: Env, id: string) => declared(env.CONVERSATION_DO.get(env.CONVERSATION_DO.idFromName(id)))

export const textChiefTables = (sql: SqlStore) => {
  // One row per SendBlue handle ever routed (dedupe of SendBlue's retries and of a repeated webhook), 7 days.
  sql.exec(`CREATE TABLE IF NOT EXISTS text_in (handle TEXT PRIMARY KEY, at INTEGER NOT NULL)`)
  // The last polite reply to a number nobody owns.
  sql.exec(`CREATE TABLE IF NOT EXISTS text_unknown (k INTEGER PRIMARY KEY CHECK (k = 1), at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS text_thread (k INTEGER PRIMARY KEY CHECK (k = 1), memo TEXT NOT NULL)`)
  // Chief messages already texted (a reply is sent at most once) and who answered when (names in play).
  sql.exec(`CREATE TABLE IF NOT EXISTS text_out (message TEXT PRIMARY KEY, agent TEXT NOT NULL, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS text_typing (k INTEGER PRIMARY KEY CHECK (k = 1), at INTEGER NOT NULL)`)
}

const sendblueHeaders = (env: Env) => ({ "sb-api-key-id": env.SENDBLUE_API_KEY!, "sb-api-secret-key": env.SENDBLUE_API_SECRET!, "Content-Type": "application/json" })

/** One text out; never retried (SendBlue has no idempotency key). Returns the handle or null. */
export const sendText = async (d: Pick<TextChiefDeps, "env" | "fetcher" | "phone">, line: string, content: string): Promise<string | null> => {
  if (!d.env.SENDBLUE_API_KEY || !d.env.SENDBLUE_API_SECRET) return null
  try {
    const res = await d.fetcher("https://api.sendblue.com/api/send-message", { method: "POST", headers: sendblueHeaders(d.env), body: JSON.stringify({ number: d.phone, from_number: line, content }) })
    const body = (await res.json().catch(() => null)) as { message_handle?: unknown; status?: unknown } | null
    const ok = res.status < 300 && body?.status !== "ERROR" && body?.status !== "DECLINED"
    console.log(JSON.stringify({ msg: "text chief send", status: res.status, state: ok ? "sent" : "failed" }))
    return ok && typeof body?.message_handle === "string" ? body.message_handle : null
  } catch {
    console.log(JSON.stringify({ msg: "text chief send", state: "indeterminate" }))
    return null
  }
}

/** The "…" bubble (iMessage only; SendBlue has no typing in SMS or groups). Best effort. */
export const sendTyping = async (d: Pick<TextChiefDeps, "env" | "fetcher" | "phone">, line: string): Promise<void> => {
  if (!d.env.SENDBLUE_API_KEY || !d.env.SENDBLUE_API_SECRET) return
  await d.fetcher("https://api.sendblue.com/api/send-typing-indicator", { method: "POST", headers: sendblueHeaders(d.env), body: JSON.stringify({ number: d.phone, from_number: line }) }).catch(() => null)
}

/** The account that owns this sender: the in-app link, else TEXT_CHIEF_PEOPLE (an account id or a verified email). */
export const ownerOf = async (d: TextChiefDeps): Promise<string | null> => {
  if (d.binding && d.binding.expires_at > d.now) return d.binding.user
  const person = address.textPersonOf(d.env.TEXT_CHIEF_PEOPLE, d.phone)
  if (!person) return null
  if (person.startsWith("user_")) return person
  const email = invites.normalizeEmail(person)
  if (!invites.isAddress(email) || !d.env.HOME_ADDRESS_KEY) return null
  const id = invites.addressId(d.env.HOME_ADDRESS_KEY, email)
  return d.env.ADDRESS_DO.get(d.env.ADDRESS_DO.idFromName(id)).linkedUser(id)
}

const chiefsOf = async (env: Env, owner: string, addr: string): Promise<Array<address.TextChief & { rev: number }>> => {
  const r = await userStub(env, owner).readOp(owner, ownerPrincipal(owner, addr), "chief.list", {})
  if (!r.ok) throw new Error(`chief.list: ${r.code}`)
  const list = ((r.value as { chiefs?: Array<ChiefRecord> }).chiefs ?? []).filter((c) => c.archived_at === null)
  return list.map((c) => ({ id: c.id, display_name: c.display_name, is_default: c.is_default, main_conversation: c.main_conversation ?? null, rev: c.rev }))
}

const replyOf = (frames: ReadonlyArray<OwnerFrame>) => frames.find((f) => f.t === "result" || f.t === "reject")

/** The memo of the person's text thread on this number (line, owner, primary Chief). */
export const threadMemo = (sql: SqlStore): ThreadMemo | null => {
  const raw = sql.exec<{ memo: string }>(`SELECT memo FROM text_thread WHERE k = 1`)[0]?.memo
  return raw ? (JSON.parse(raw) as ThreadMemo) : null
}

export type InboundOutcome = "duplicate" | "ignored" | "unknown_sender" | "unknown_replied" | "command" | "routed" | "no_chief" | "failed"

/**
 * One verified inbound text (SendBlue's record, not the webhook body). Returns what happened, for the
 * log and the tests; never throws on a provider error.
 */
export const textChiefInbound = async (d: TextChiefDeps, m: SendblueMessage): Promise<InboundOutcome> => {
  const { env, sql, now } = d
  textChiefTables(sql)
  sql.exec(`DELETE FROM text_in WHERE at < ?`, now - 7 * 24 * 3_600_000)
  if (sql.exec(`SELECT 1 FROM text_in WHERE handle = ?`, m.message_handle).length > 0) return "duplicate"
  sql.exec(`INSERT INTO text_in (handle, at) VALUES (?, ?)`, m.message_handle, now)
  const lines = address.parseTextLines(env.TEXT_CHIEF_LINES, env.SENDBLUE_FROM_NUMBER)
  const line = lines.find((l) => l.number === m.line)
  // Groups are not routed yet (one person's Chief must never answer a group by accident).
  if (!line || m.group_id) return "ignored"
  const owner = await ownerOf(d)
  if (!owner || (line.owner && line.owner !== owner && address.textPersonOf(env.TEXT_CHIEF_PEOPLE, d.phone) !== line.owner)) {
    const last = sql.exec<{ at: number }>(`SELECT at FROM text_unknown WHERE k = 1`)[0]?.at
    if (last !== undefined && now - last < UNKNOWN_REPLY_EVERY_MS) return "unknown_sender"
    sql.exec(`INSERT INTO text_unknown (k, at) VALUES (1, ?) ON CONFLICT (k) DO UPDATE SET at = excluded.at`, now)
    await sendText(d, line.number, address.UNKNOWN_SENDER_TEXT)
    return "unknown_replied"
  }
  if (m.service === "iMessage") void sendTyping(d, line.number)
  let chiefs: Awaited<ReturnType<typeof chiefsOf>>
  try {
    chiefs = await chiefsOf(env, owner, d.address)
  } catch {
    await sendText(d, line.number, "Chief could not be reached just now. Please try again in a minute.")
    return "failed"
  }
  const fixed = line.chief ? (chiefs.find((c) => c.id === line.chief) ?? null) : null
  const media = m.media_url ? `\n${m.media_url}` : ""
  const cmd = address.parseTextCommand(m.content + media, chiefs, fixed)
  const primary = address.primaryChief(chiefs)
  switch (cmd.kind) {
    case "help":
      await sendText(d, line.number, address.TEXT_HELP)
      return "command"
    case "list":
      await sendText(d, line.number, address.chiefListText(chiefs))
      return "command"
    case "unknown_chief":
      await sendText(d, line.number, `No Chief is called "${cmd.name.slice(0, 60)}".\n\n${address.chiefListText(chiefs)}`)
      return "command"
    case "no_chief":
      await sendText(d, line.number, address.chiefListText([]))
      return "no_chief"
    case "primary": {
      if (cmd.chief.is_default) {
        await sendText(d, line.number, `${cmd.chief.display_name} is already your primary Chief.`)
        return "command"
      }
      const rev = chiefs.find((c) => c.id === cmd.chief.id)!.rev
      const res = await userStub(env, owner).submit(owner, ownerPrincipal(owner, d.address), { t: "op", op: "chief.update", params: { chief: cmd.chief.id, expected_rev: rev, is_default: true }, idempotency_key: `text:${m.message_handle}`, origin: "remote" })
      const reply = replyOf(res.frames)
      await sendText(d, line.number, reply?.t === "result" ? `${cmd.chief.display_name} is now your primary Chief. Your texts go to ${cmd.chief.display_name}.` : "That did not work. Please try again in the cmux app.")
      if (reply?.t === "result") remember(sql, { line: line.number, owner, primary: cmd.chief.id, service: m.service ?? "SMS" })
      return "command"
    }
    case "send": {
      const conv = cmd.chief.main_conversation
      if (!conv || !cmd.text) return "ignored"
      remember(sql, { line: line.number, owner, primary: fixed?.id ?? primary?.id ?? cmd.chief.id, service: m.service ?? "SMS" })
      const stub = conversationStub(env, conv)
      await stub.textBridge(conv, { address: d.address, until: now + BRIDGE_MS })
      const key = `sms_${m.message_handle}`
      const res = await stub.submit(conv, ownerPrincipal(owner, d.address), { t: "op", op: "message.send", params: { client_msg_id: key, parts: [{ type: "text", text: cmd.text }] }, idempotency_key: key, origin: "remote" })
      const reply = replyOf(res.frames)
      if (reply?.t !== "result") {
        console.log(JSON.stringify({ msg: "text chief route", state: "refused", code: reply?.t === "reject" ? reply.code : "no_reply" }))
        await sendText(d, line.number, "Chief could not take that text just now. Please try again in a minute.")
        return "failed"
      }
      return "routed"
    }
  }
}

const remember = (sql: SqlStore, memo: ThreadMemo) => sql.exec(`INSERT INTO text_thread (k, memo) VALUES (1, ?) ON CONFLICT (k) DO UPDATE SET memo = excluded.memo`, JSON.stringify(memo))

/**
 * A Chief's message in a conversation with a live text bridge: sent back as a text, once per message,
 * its name first when more than one Chief is in play (another Chief answered lately, or this one is
 * not the primary).
 */
export const textChiefReply = async (d: Omit<TextChiefDeps, "binding" | "address">, reply: { message: string; agent: string; name: string; text: string }): Promise<"sent" | "skipped" | "failed"> => {
  const { sql, now } = d
  textChiefTables(sql)
  const memo = threadMemo(sql)
  if (!memo || !reply.text.trim()) return "skipped"
  if (sql.exec(`SELECT 1 FROM text_out WHERE message = ?`, reply.message).length > 0) return "skipped"
  // Recorded before the call: a restart never sends the same reply twice.
  sql.exec(`INSERT INTO text_out (message, agent, at) VALUES (?, ?, ?)`, reply.message, reply.agent, now)
  sql.exec(`DELETE FROM text_out WHERE at < ?`, now - 7 * 24 * 3_600_000)
  const others = sql.exec(`SELECT 1 FROM text_out WHERE agent <> ? AND at >= ? LIMIT 1`, reply.agent, now - IN_PLAY_MS).length > 0
  const prefix = others || reply.agent !== memo.primary
  return (await sendText(d, memo.line, address.replyText(reply.text, reply.name, prefix))) ? "sent" : "failed"
}

/** A Chief started typing in a bridged conversation: the "…" bubble, at most every few seconds. */
export const textChiefTyping = async (d: Omit<TextChiefDeps, "binding" | "address">): Promise<void> => {
  textChiefTables(d.sql)
  const memo = threadMemo(d.sql)
  if (!memo || memo.service !== "iMessage") return
  const last = d.sql.exec<{ at: number }>(`SELECT at FROM text_typing WHERE k = 1`)[0]?.at
  if (last !== undefined && d.now - last < TYPING_EVERY_MS) return
  d.sql.exec(`INSERT INTO text_typing (k, at) VALUES (1, ?) ON CONFLICT (k) DO UPDATE SET at = excluded.at`, d.now)
  await sendTyping(d, memo.line)
}
