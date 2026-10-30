import { env as testEnv } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { readRuns } from "../src/chief-brain/brain-runs.ts"
import { LiveRuns, type LiveRunsDeps } from "../src/chief-brain-opencode/live-runs.ts"

import { handleOpencodeRuns } from "../src/chief-brain-opencode/routes.ts"
import type { Env } from "../src/env.ts"

type Turn = {
  id: string
  conversation: string
  started: number
  trigger_message: string
  trigger_kind: string
  trigger_thread_root: string | null
  last_seq: number
  status: string
  model: string
  ended: number | null
  submitted: number
  input: string | null
  reply: string | null
  post: string | null
  posted_message: string | null
  turn_key: string | null
  post_tries: number
  post_key: number
}

const result = <T,>(rows: Array<T>) => ({ toArray: () => rows, one: () => rows[0] })

/** A focused SqlStorage fake that applies the pagination predicates used by both readers. */
class RunsSql {
  readonly turns: Array<Turn>
  readonly bodies = new Map<string, string>()
  constructor(turns: Array<Turn>) {
    this.turns = turns
    for (const turn of turns) this.bodies.set(turn.id, JSON.stringify({ id: turn.id, conversation: turn.conversation, run: turn.id, started_at: turn.started, status: "done", model: "fake" }))
  }
  exec<T>(query: string, ...args: Array<unknown>) {
    if (query.includes("SELECT id FROM cb_turn") || query.includes("SELECT id, started FROM cb_turn")) {
      const conversation = String(args[0])
      const before = Number(args[1])
      const rows = this.turns
        .filter((turn) => turn.conversation === conversation && (query.includes("started = ?") ? turn.started === before : turn.started < before))
        .sort((a, b) => b.started - a.started || b.id.localeCompare(a.id))
      const limit = args[2] === undefined ? undefined : Number(args[2])
      return result((limit === undefined ? rows : rows.slice(0, limit)).map(({ id, started }) => query.includes("SELECT id, started") ? { id, started } : { id })) as ReturnType<typeof result<T>>
    }
    if (query.includes("SELECT 1 FROM cb_turn")) {
      const conversation = String(args[0])
      const before = Number(args[1])
      return result(this.turns.some((turn) => turn.conversation === conversation && turn.started < before) ? [{ one: 1 }] : []) as ReturnType<typeof result<T>>
    }
    if (query.includes("SELECT * FROM cb_turn")) return result(this.turns.filter((turn) => turn.id === String(args[0]))) as ReturnType<typeof result<T>>
    if (query.includes("SELECT body FROM oc_run")) return result(this.bodies.has(String(args[0])) ? [{ body: this.bodies.get(String(args[0]))! }] : []) as ReturnType<typeof result<T>>
    if (query.includes("COUNT(*) AS n, MAX(seq) AS last")) return result([{ n: 0, last: null }]) as ReturnType<typeof result<T>>
    if (query.includes("SELECT message FROM cb_inbox")) return result([]) as ReturnType<typeof result<T>>
    if (query.includes("SELECT calls, input, output")) return result([]) as ReturnType<typeof result<T>>
    if (query.includes("SELECT request_at, first_token_at")) return result([]) as ReturnType<typeof result<T>>
    if (query.includes("SELECT mark, at FROM cb_marks")) return result([]) as ReturnType<typeof result<T>>
    if (query.includes("SELECT value FROM cb_config")) return result([]) as ReturnType<typeof result<T>>
    throw new Error(`Unhandled SQL: ${query}`)
  }
}

const turnsFor = (conversation: string): Array<Turn> => [
  ...Array.from({ length: 101 }, (_, i) => ({
    id: `run-${String(i).padStart(3, "0")}`,
    conversation,
    started: 30,
    trigger_message: "",
    trigger_kind: "chief",
    trigger_thread_root: null,
    last_seq: 0,
    status: "done",
    model: "fake",
    ended: null,
    submitted: 0,
    input: null,
    reply: null,
    post: "none",
    posted_message: null,
    turn_key: null,
    post_tries: 0,
    post_key: 0
  })),
  {
    id: "run-old",
    conversation,
    started: 20,
    trigger_message: "",
    trigger_kind: "chief",
    trigger_thread_root: null,
    last_seq: 0,
    status: "done",
    model: "fake",
    ended: null,
    submitted: 0,
    input: null,
    reply: null,
    post: "none",
    posted_message: null,
    turn_key: null,
    post_tries: 0,
    post_key: 0
  }
]

const pageThrough = (page: (before: number | undefined) => { runs: Array<{ id: string; started_at: number }>; has_more: boolean }) => {
  const seen: Array<string> = []
  let before: number | undefined
  let hasMore = true
  while (hasMore) {
    const result = page(before)
    seen.push(...result.runs.map((run) => run.id))
    before = result.runs.at(-1)?.started_at
    hasMore = result.has_more
  }
  return seen
}

describe("Cloud Chief run pagination", () => {
  it("keeps every timestamp tie in the brain reader across pages", () => {
    const sql = new RunsSql(turnsFor("conv"))
    const ids = pageThrough((before) => readRuns(sql as never, "agent", "conv", before, 100))
    expect(ids).toHaveLength(102)
    expect(new Set(ids).size).toBe(102)
  })

  it("keeps every timestamp tie in the live reader across pages", () => {
    const sql = new RunsSql(turnsFor("conv"))
    const deps: LiveRunsDeps = {
      env: {} as never,
      sql: sql as never,
      tx: (fn) => fn(),
      waitUntil: () => undefined,
      get: (name) => name === "agent" ? "agent" : undefined,
      set: () => undefined,
      wakeOf: () => undefined
    }
    const live = new LiveRuns(deps)
    const ids = pageThrough((before) => live.runs("conv", before, 100) as { runs: Array<{ id: string; started_at: number }>; has_more: boolean })
    expect(ids).toHaveLength(102)
    expect(new Set(ids).size).toBe(102)
  })
})


describe("Cloud Chief durable/P run route pagination", () => {
  const conversation = "conv_00000000000000000000000000"
  const fixtures = turnsFor(conversation)
  const tied = fixtures.slice(0, 101)
  const old = fixtures.slice(101)

  it.each([
    { name: "P-only oversized tie", durable: [], pi: fixtures, sizes: [101, 1] },
    { name: "durable oversized tie with older P history", durable: tied, pi: old, sizes: [101, 1] },
    { name: "tie spanning a full durable page and P", durable: tied.slice(0, 100), pi: [...tied.slice(100), ...old], sizes: [101, 1] },
    { name: "short durable page and oversized P tie", durable: tied.slice(0, 1), pi: [...tied.slice(1), ...old], sizes: [101, 1] },
    { name: "terminal tie without older history", durable: tied.slice(0, 1), pi: tied.slice(1), sizes: [101] },
    { name: "interleaved durable and P timestamps", durable: old, pi: tied, sizes: [101, 1] }
  ])("keeps all runs exactly once through routes.ts: $name", async ({ durable, pi, sizes }) => {
    const durableSql = new RunsSql(durable)
    const piSql = new RunsSql(pi)
    const namespace = (reader: unknown) => ({ idFromName: (name: string) => name, get: () => reader })
    const bindings = testEnv as unknown as Env
    const token = await new SignJWT({ email: "paging@example.com", email_verified: true })
      .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
      .setIssuer(`https://api.stack-auth.com/api/v1/projects/${bindings.STACK_PROJECT_ID}`)
      .setAudience(bindings.STACK_PROJECT_ID).setSubject("chief-paging-route").setIssuedAt().setExpirationTime("10m")
      .sign(await importJWK(JSON.parse((testEnv as unknown as { STACK_TEST_PRIVATE_JWK: string }).STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
    const env = {
      ...bindings,
      CHIEF_DURABLE_ENABLED: "1",
      CHIEF_DURABLE_DO: namespace({ runs: async (_conversation: string, before: number | undefined, limit: number) => readRuns(durableSql as never, "agent", conversation, before, limit) }),
      MUX_DO: namespace({ brainImplOf: async () => "durable" }),
      CONVERSATION_DO: namespace({ readOp: async () => ({ ok: true }) })
    } as unknown as Env
    const ids: Array<string> = []
    const pageSizes: Array<number> = []
    let before: number | undefined
    for (let page = 0; page < 5; page++) {
      const url = new URL(`https://api.test/v1/chiefs/agent/runs?conversation=${conversation}&limit=100`)
      if (before !== undefined) url.searchParams.set("before", String(before))
      const response = await handleOpencodeRuns(new Request(url, { headers: { authorization: `Bearer ${token}` } }), env, "agent", undefined, async () =>
        Response.json({ ok: true, value: readRuns(piSql as never, "agent", conversation, before, 100) }))
      expect(response.status).toBe(200)
      const { value } = await response.json() as { value: { runs: Array<{ id: string; started_at: number }>; has_more: boolean } }
      pageSizes.push(value.runs.length)
      ids.push(...value.runs.map((run) => run.id))
      expect(value.has_more).toBe(page < sizes.length - 1)
      if (!value.has_more) break
      const cursor = value.runs.at(-1)!.started_at
      expect(cursor).toBeLessThan(before ?? Number.MAX_SAFE_INTEGER)
      before = cursor
    }
    expect(pageSizes).toEqual(sizes)
    const expected = [...durable, ...pi].sort((a, b) => b.started - a.started || b.id.localeCompare(a.id)).map((row) => row.id)
    expect(ids).toEqual(expected)
    expect(new Set(ids).size).toBe(expected.length)
  })
})
