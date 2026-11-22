import { sha256Hex, type AgentEvent, type StoredEvent } from "../hand-wire.ts"

/** The caller rechecks the live default-machine binding and full Hand grant on every request. */
export type MachineRpc = (method: string, params: unknown, timeoutMs: number, feature?: string) => Promise<unknown>
type Start = { operation: string; harness: "claude" | "codex"; cwd: string; prompt: string }
type Session = { id: string; name: string; harness: "claude" | "codex"; cwd: string; digest: string; created: number; prompt: string; delivery: string }
type RecordValue = Record<string, unknown>
type Page = { events: Array<RecordValue>; hasMore: boolean; lastSeq: number; pageThrough: number; createdAt: number }
const PREFIX = "chief-machine-acp:"
const TAG = "chief-machine-request"
const object = (value: unknown): RecordValue => value !== null && typeof value === "object" && !Array.isArray(value) ? value as RecordValue : {}
const integer = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0
const fail = (): never => { throw new Error("chief.machine.protocol_invalid") }
const nonempty = (value: unknown): value is string => typeof value === "string" && value.length > 0
const codeOf = (error: unknown) => object(error).code

const decode = (session: string): Session => {
  if (!session.startsWith(PREFIX)) return fail()
  let s: Session
  try { s = JSON.parse(session.slice(PREFIX.length)) as Session } catch { return fail() }
  if (!s || !nonempty(s.id) || !nonempty(s.name) || !nonempty(s.cwd) || !nonempty(s.digest) || !nonempty(s.prompt) || !nonempty(s.delivery) || !integer(s.created) || !["claude", "codex"].includes(s.harness)) return fail()
  return s
}

const checkedInfo = (raw: unknown, expected: Omit<Session, "id" | "created" | "delivery"> & { id?: string; created?: number }): RecordValue => {
  const info = object(raw)
  if (!nonempty(info.sessionId) || info.name !== expected.name || info.harness !== expected.harness || info.cwd !== expected.cwd || info.policy !== "approve-all" || object(info.tags)[TAG] !== expected.digest || !integer(info.createdAt)) return fail()
  if (expected.id !== undefined && info.sessionId !== expected.id || expected.created !== undefined && info.createdAt !== expected.created) return fail()
  // A moved or watched journal is no longer this machine's execution target.
  if (info.moving === true || info.movedTo != null || info.watching != null) return fail()
  return info
}

/**
 * The operation and original prompt are persisted by the brain before this call. A unique name
 * reconciles a lost create reply; send_queue persists the exact prompt and deduplicates its ID.
 * A request digest refuses a changed prompt under the same operation instead of starting twice.
 */
export const startMachineAgent = async (rpc: MachineRpc, args: Start): Promise<{ session: string }> => {
  if (!args.operation || !args.cwd.startsWith("/") || !["claude", "codex"].includes(args.harness)) return fail()
  const operation = await sha256Hex(args.operation)
  const expected = { name: `chief-build-${operation}`, harness: args.harness, cwd: args.cwd, prompt: `chief-build:${operation}`, digest: await sha256Hex(JSON.stringify([args.operation, args.harness, args.cwd, args.prompt])) }
  let info: unknown
  try {
    info = await rpc("_acpmux/info", { sessionId: expected.name }, 30_000)
  } catch (error) {
    // Only a definitive daemon not-found permits creation. A transport timeout is ambiguous.
    if (codeOf(error) !== -32002) throw error
    try {
      await rpc("session/new", {
        cwd: args.cwd, mcpServers: [],
        _meta: { acpmux: { name: expected.name, harness: args.harness, policy: "approve-all", tags: { [TAG]: expected.digest } } },
      }, 90_000)
    } catch (error) {
      // A concurrent create or lost create reply can already have published the stable name.
      try { info = await rpc("_acpmux/info", { sessionId: expected.name }, 30_000) } catch (lookup) {
        // Only a definitive create refusal followed by a definitive missing name proves the
        // prompt was never submitted. An uncertain create or enqueue remains retryable.
        if (typeof codeOf(error) === "number" && codeOf(lookup) === -32002) throw Object.assign(new Error("chief.machine.start_refused"), { code: codeOf(error), beforePrompt: true })
        throw error
      }
    }
    info ??= await rpc("_acpmux/info", { sessionId: expected.name }, 30_000)
  }
  const checked = checkedInfo(info, expected)
  const id = checked.sessionId as string
  // No gateway route: the declared Claude/Codex harness uses the owner's provider sign-in.
  const delivery = object(await rpc("_acpmux/send_queue", { request: {
    sessionId: id,
    prompt: [{ type: "text", text: args.prompt }],
    _meta: { acpmux: { promptId: expected.prompt, steer: false, resend: true } },
  } }, 30_000))
  if (!nonempty(delivery.deliveryId) || delivery.target !== id || delivery.promptId !== expected.prompt) return fail()
  const session: Session = { ...expected, id, created: checked.createdAt as number, delivery: delivery.deliveryId }
  return { session: PREFIX + JSON.stringify(session) }
}

const readPage = async (rpc: MachineRpc, session: Session, after: number): Promise<Page> => {
  // Bounds each transfer, never total output. pageThrough includes intentionally omitted rows.
  const page = object(await rpc("_acpmux/events", { sessionId: session.id, afterSeq: after, limit: 500, maxBytes: 512 * 1024 }, 30_000))
  if (!Array.isArray(page.events) || typeof page.hasMore !== "boolean" || !integer(page.lastSeq) || !integer(page.pageThrough) || page.pageThrough < after || page.pageThrough > page.lastSeq || page.createdAt !== session.created) return fail()
  let previous = after
  for (const raw of page.events) {
    const event = object(raw)
    if (event.sessionId !== session.id || !integer(event.seq) || event.seq <= previous || event.seq > page.pageThrough || !integer(event.at)) return fail()
    previous = event.seq
  }
  if (page.hasMore && page.pageThrough <= after) return fail()
  return page as Page
}

const optional = (value: unknown): string | undefined => typeof value === "string" ? value : undefined
const summarize = (raw: RecordValue): AgentEvent | null => {
  const msg = object(raw.msg)
  const params = object(msg.params)
  const update = object(params.update)
  if (raw.dir === "in" && typeof raw.kind === "string" && !raw.kind.endsWith(".replay") && msg.method === "session/update") {
    if (update.sessionUpdate === "agent_message_chunk" && object(object(params._meta).acpmux).subagent === undefined) {
      const text = object(update.content).text
      return typeof text === "string" ? { kind: "text", text } : null
    }
    if (update.sessionUpdate === "tool_call" || update.sessionUpdate === "tool_call_update") return {
      kind: "tool", update: update.sessionUpdate === "tool_call_update",
      id: optional(update.toolCallId), title: optional(update.title), tool_kind: optional(update.kind), status: optional(update.status),
    }
  }
  if (raw.dir !== "mux") return null
  switch (raw.kind) {
    case "turn_started": return { kind: "turn_start" }
    case "permission_request": case "permission_reissued": return { kind: "permission", permission_id: optional(msg.permissionId), title: optional(object(object(msg.request).toolCall).title) }
    // turn_end precedes the persisted outcome. Only turn_result can finish a build.
    // turn_error lacks promptId. Its following turn_result binds the persisted refusal.
    case "turn_error": return null
    default: return null
  }
}

export const machineAgentEvents = async (rpc: MachineRpc, encoded: string, after: number, wait: number): Promise<{ events: Array<StoredEvent>; last_seq: number; head_seq: number }> => {
  if (!integer(after) || !Number.isFinite(wait) || wait < 0) return fail()
  const session = decode(encoded)
  const info = checkedInfo(await rpc("_acpmux/info", { sessionId: session.id }, 30_000), session)
  const delivery = object(await rpc("_acpmux/send_status", { deliveryId: session.delivery, waitMs: Math.min(wait, 10_000) }, 15_000))
  if (delivery.deliveryId !== session.delivery || delivery.target !== session.id || delivery.promptId !== session.prompt || !["queued", "delivering", "delivered", "held", "failed"].includes(delivery.status as string)) return fail()
  if (delivery.status === "failed" || delivery.status === "held") {
    const seq = after + 1
    return { events: [{ seq, session: encoded, at: Date.now(), event: { kind: "error", message: "The machine refused the build request." } }], last_seq: seq, head_seq: seq }
  }
  let page = await readPage(rpc, session, after)
  if (page.pageThrough === after && wait > 0 && delivery.status === "delivered") {
    if (!integer(info.stateSeq)) return fail()
    // One server-side condition wait, bound to this exact journal and state revision.
    await rpc("_acpmux/wait", { sessions: [session.id], until: ["ready", "permission", "closed"], afterSeq: { [session.id]: info.stateSeq }, timeoutMs: Math.min(wait, 30_000) }, Math.min(wait, 30_000) + 5_000)
    page = await readPage(rpc, session, after)
  }
  const events: Array<StoredEvent> = []
  for (const raw of page.events) {
    let event = summarize(raw)
    if (raw.dir === "mux" && raw.kind === "turn_result" && object(raw.msg).promptId === session.prompt) {
      // The original prompt ledger distinguishes completion, a restored failure and cancellation.
      try {
        const outcome = object(await rpc("_acpmux/wait", { sessionId: session.id, until: ["promptOutcome"], promptId: session.prompt }, 30_000))
        const status = object(raw.msg).status
        event = status === "cancelled" || outcome.stopReason === "cancelled" ? { kind: "error", message: "The machine build was cancelled." }
          : status === "failed" ? { kind: "error", message: "The machine agent failed." }
          : { kind: "turn_end", stop_reason: optional(outcome.stopReason) }
      } catch (error) {
        if (typeof codeOf(error) !== "number") throw error
        const msg = object(raw.msg)
        const kind = msg.errorKind
        // Only the original prompt's settled failed outcome can request sign-in. A code
        // mismatch, cancellation, transport error or prose mentioning login is not evidence.
        const auth = msg.status === "failed" && msg.code === codeOf(error) && (kind === "auth.signed_out" || kind === "auth.expired") ? kind : undefined
        event = { kind: "error", message: "The machine agent failed.", code: codeOf(error) as number, ...(auth ? { error_kind: auth } : {}) }
      }
    }
    if (event) events.push({ seq: raw.seq as number, session: encoded, at: raw.at as number, event })
  }
  return { events, last_seq: page.pageThrough, head_seq: page.lastSeq }
}

/** Keep the named journal and prompt ledger so a delayed retry cannot execute the build again. */
export const stopMachineAgent = async (rpc: MachineRpc, encoded: string): Promise<void> => {
  const session = decode(encoded)
  checkedInfo(await rpc("_acpmux/info", { sessionId: session.id }, 30_000), session)
  await rpc("_acpmux/kill", { sessionId: session.id, purge: false }, 30_000)
}
