import { describe, expect, it } from "vitest"
import { readRuns } from "../src/chief-brain/brain-runs.ts"
import { LiveRuns, type LiveRunsDeps } from "../src/chief-brain-opencode/live-runs.ts"

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
