import { expect } from "vitest"
import { worker } from "./cloud-bind-support.ts"
import { advance, as, chatStub, fakeCloud, person, vmBearer, type Person } from "./auto-sessions-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Replays one case of the Auto mode conformance vectors against the real routes. The vectors are
 * cmux-tui/crates/cmux-auto-session/fixtures/conformance.json (its `about` says what a step is); the Rust test
 * cmux-tui/crates/cmux-auto-session/tests/conformance replays the same file against FakeAutoCloud, so the fake and
 * this store answer alike.
 *
 * A case gets an owner of its own. Time moves only by a step's `advanceMs`; then the alarm of every chat the case
 * made is run by hand, as the store's own tests do (auto-sessions-support.ts `lapse`).
 */
export type Step = {
  readonly advanceMs?: number
  readonly by: string
  readonly op: string
  readonly id?: string
  readonly body?: Record<string, unknown>
  readonly query?: Record<string, number>
  readonly sha256?: string
  readonly text?: string
  readonly fence?: { readonly holder: string; readonly epoch: number }
  readonly expect?: unknown
  readonly refuse?: { readonly status: number; readonly code: string; readonly lastSeq?: number; readonly missing?: ReadonlyArray<string>; readonly session?: unknown }
  readonly disputed?: string
}
export type Case = { readonly name: string; readonly steps: ReadonlyArray<Step> }

type Answer = { readonly status: number; readonly body: unknown }
type World = { readonly owner: Person; readonly bearers: Map<string, string>; readonly chats: Set<string>; created: string }

const ROOT = "/v1/auto-sessions"

/**
 * How `expect` differs from `actual` ("" when it matches): an object by the keys it names, a list item by item, anything else by
 * value. `"$set"` matches any value that is there and not null: a time, which no vector can name.
 */
export const differs = (expected: unknown, actual: unknown, at = "answer"): string => {
  if (expected === "$set") return (actual ?? null) === null ? `${at}: expected a value, got ${JSON.stringify(actual)}` : ""
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return `${at}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    return expected.map((e, i) => differs(e, actual[i], `${at}[${i}]`)).find((d) => d !== "") ?? ""
  }
  if (expected !== null && typeof expected === "object") {
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) return `${at}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
    const got = actual as Record<string, unknown>
    return (
      Object.entries(expected)
        .map(([k, e]) => differs(e, got[k] ?? null, `${at}.${k}`))
        .find((d) => d !== "") ?? ""
    )
  }
  return expected === (actual ?? null) ? "" : `${at}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`
}

const query = (q: Record<string, number> | undefined): string => {
  const pairs = Object.entries(q ?? {}).map(([k, v]) => `${k}=${v}`)
  return pairs.length > 0 ? `?${pairs.join("&")}` : ""
}

/** The step's request: method, path after the routes' root, and a JSON body or a chunk's bytes. */
const requestOf = (s: Step, id: string, team: string): { readonly method: string; readonly path: string; readonly json?: unknown; readonly bytes?: Uint8Array; readonly headers?: Record<string, string> } => {
  const chunk = `/${id}/chunks/${s.sha256}`
  switch (s.op) {
    case "machine":
      return { method: "GET", path: "/machine" }
    case "set_machine":
      return { method: "PUT", path: "/machine", json: { ...s.body, team: s.body?.team === "$team" ? team : s.body?.team } }
    case "put":
      return { method: "PUT", path: `/${id}`, json: s.body }
    case "create":
      return { method: "POST", path: "", json: s.body }
    case "list":
      return { method: "GET", path: query(s.query) }
    case "get":
      return { method: "GET", path: `/${id}` }
    case "wait":
      return { method: "GET", path: `/${id}/wait${query(s.query)}` }
    case "lease":
      return { method: "POST", path: `/${id}/lease`, json: s.body }
    case "release":
      return { method: "POST", path: `/${id}/release`, json: s.body }
    case "append_events":
      return { method: "POST", path: `/${id}/events`, json: s.body }
    case "events":
      return { method: "GET", path: `/${id}/events${query(s.query)}` }
    case "put_chunk":
      return { method: "PUT", path: chunk, bytes: new TextEncoder().encode(s.text ?? ""), headers: { "x-cmux-auto-holder": s.fence?.holder ?? "", "x-cmux-auto-epoch": String(s.fence?.epoch ?? "") } }
    case "chunk":
      return { method: "GET", path: chunk }
    case "post_snapshot":
      return { method: "POST", path: `/${id}/snapshot`, json: s.body }
    case "snapshot":
      return { method: "GET", path: `/${id}/snapshot` }
    case "post_inbox":
      return { method: "POST", path: `/${id}/inbox`, json: s.body }
    case "inbox":
      return { method: "GET", path: `/${id}/inbox${query(s.query)}` }
    case "ack_inbox":
      return { method: "POST", path: `/${id}/inbox/ack`, json: s.body }
    case "keep":
      return { method: "POST", path: `/${id}/keep`, json: s.body }
    case "move":
      return { method: "POST", path: `/${id}/move`, json: s.body }
    case "give":
      return { method: "POST", path: `/${id}/give`, json: s.body }
    case "assignments":
      return { method: "GET", path: `/assignments${query(s.query)}` }
    case "ack_assignment":
      return { method: "POST", path: `/${id}/assignment/ack`, json: s.body }
    default:
      throw new Error(`the vectors name an operation this replayer does not know: ${s.op}`)
  }
}

const bearerOf = async (w: World, by: string): Promise<string> => {
  if (by === "owner") return w.owner.installToken
  const machine = /^machine:(.+)$/.exec(by)?.[1]
  if (!machine) throw new Error(`the vectors name a caller this replayer does not know: ${by}`)
  const known = w.bearers.get(machine) ?? (await vmBearer(w.owner, machine))
  w.bearers.set(machine, known)
  return known
}

const send = async (w: World, s: Step): Promise<Answer> => {
  const id = s.id === "$created" ? w.created : (s.id ?? "")
  const r = requestOf(s, id, w.owner.team)
  const headers = { ...as(await bearerOf(w, s.by)), ...(r.json === undefined ? {} : { "content-type": "application/json" }), ...r.headers }
  const response = await worker.fetch(`https://api.test${ROOT}${r.path}`, { method: r.method, headers, ...(r.json !== undefined ? { body: JSON.stringify(r.json) } : r.bytes ? { body: r.bytes } : {}) })
  const text = await response.text()
  // A chunk's bytes answer as the text they are; every other answer is JSON, or empty.
  if (s.op === "chunk" && response.ok) return { status: response.status, body: { text } }
  return { status: response.status, body: text ? JSON.parse(text) : null }
}

/** The clock moves on, and the lease alarm of every chat of the case runs. */
const move = async (w: World, ms: number): Promise<void> => {
  advance(ms)
  for (const id of w.chats) await fireAlarm(chatStub(w.owner.user, id))
}

const check = (s: Step, got: Answer, at: string): void => {
  const shown = `${at}: ${s.by} ${s.op} answered ${got.status} ${JSON.stringify(got.body)}`
  if (!s.refuse) {
    expect(got.status >= 200 && got.status < 300, shown).toBe(true)
    if (s.expect !== undefined) expect(differs(s.expect, got.body), shown).toBe("")
    return
  }
  const body = (got.body ?? {}) as { error?: { code?: string } }
  const { status, code, ...rest } = s.refuse
  expect({ status: got.status, code: body.error?.code }, shown).toEqual({ status, code })
  expect(differs(rest, body), shown).toBe("")
}

export const replay = async (c: Case, index: number): Promise<void> => {
  const owner = await person(`conformance-${index}`)
  // Machine starts go to a fake of the platform's Cloud; the vectors do not cover them.
  await fakeCloud(owner.user)
  const w: World = { owner, bearers: new Map(), chats: new Set(), created: "" }
  for (const [n, s] of c.steps.entries()) {
    if (s.advanceMs) await move(w, s.advanceMs)
    const got = await send(w, s)
    const made = (got.body as { session?: { id?: string } } | null)?.session?.id
    if (got.status < 300 && typeof made === "string" && (s.op === "put" || s.op === "create")) w.chats.add(made)
    if (got.status < 300 && typeof made === "string" && s.op === "create") w.created = made
    check(s, got, `step ${n + 1} of ${c.steps.length}`)
  }
}
