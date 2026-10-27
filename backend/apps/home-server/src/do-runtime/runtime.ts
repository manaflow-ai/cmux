import { Database } from "bun:sqlite"
import { createHash } from "node:crypto"
import { mkdirSync } from "node:fs"
import { join } from "node:path"
import { ObjectState, type ObjectId } from "./object-state.ts"
import { ObjectStorage } from "./storage.ts"

/** A Durable Object class as the runtime builds it: `new Class(ctx, env)`. */
export type ObjectClass = new (ctx: never, env: never) => object

/** One live object: its instance and state. */
interface LiveObject {
  readonly instance: Record<string, unknown> & { alarm?: (info?: { retryCount: number; isRetry: boolean }) => Promise<void> | void }
  readonly state: ObjectState
  readonly ready: Promise<void>
  timer?: ReturnType<typeof setTimeout>
  retry: number
}

/** Longest timer setTimeout takes; a later alarm re-arms when this one fires. */
const MAX_TIMER_MS = 2_147_000_000
/** Alarm retries after a throw: 2^n seconds, at most this many (Durable Objects retry 6 times). */
const ALARM_RETRIES = 6

const hex = (text: string, n = 32) => createHash("sha256").update(text).digest("hex").slice(0, n)

/** Copies a value across an RPC boundary (Workers RPC structured-clones arguments and results). */
const copy = <T>(v: T): T => (v instanceof Request || v instanceof Response || v === undefined ? v : structuredClone(v))

/**
 * A small Durable Object runtime for the self-hosted server: one SQLite file per object under
 * `<dataDir>/do/<class>/`, namespaces with `idFromName` and `get`, RPC stubs that copy arguments
 * and results, the start gate, and alarms that survive a restart (an index of every object made).
 */
export class DoRuntime {
  private readonly classes = new Map<string, { className: string; ctor: ObjectClass }>()
  private readonly live = new Map<string, LiveObject>()
  private readonly index: Database
  private stopped = false

  constructor(
    private readonly dataDir: string,
    readonly env: Record<string, unknown>
  ) {
    mkdirSync(join(dataDir, "do"), { recursive: true })
    this.index = new Database(join(dataDir, "do", "index.sqlite"), { create: true })
    this.index.run("PRAGMA journal_mode = WAL")
    this.index.run("CREATE TABLE IF NOT EXISTS objects (binding TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (binding, name))")
  }

  /** Binds `className` as `env[binding]` (a namespace). */
  register(binding: string, className: string, ctor: ObjectClass): void {
    this.classes.set(binding, { className, ctor })
    this.env[binding] = this.namespace(binding)
  }

  /** The namespace object code reads from env: `idFromName`, `idFromString`, `get`, `getByName`. */
  namespace(binding: string) {
    const idFor = (name: string): ObjectId => {
      const str = hex(`${binding}\u0000${name}`, 64)
      return { name, toString: () => str, equals: (o) => o.toString() === str }
    }
    const byHex = new Map<string, string>()
    return {
      idFromName: (name: string) => {
        const id = idFor(name)
        byHex.set(id.toString(), name)
        return id
      },
      idFromString: (s: string) => {
        const name = byHex.get(s)
        if (name === undefined) throw new Error("unknown object id on this server")
        return idFor(name)
      },
      newUniqueId: () => idFor(crypto.randomUUID()),
      get: (id: ObjectId) => this.stub(binding, id.name),
      getByName: (name: string) => this.stub(binding, name)
    }
  }

  /** A stub: every property is an async method on the object; arguments and results are copied. */
  stub(binding: string, name: string): Record<string, (...args: Array<unknown>) => Promise<unknown>> {
    return new Proxy({} as Record<string, (...args: Array<unknown>) => Promise<unknown>>, {
      get: (_t, prop) => {
        if (prop === "then" || typeof prop !== "string") return undefined
        if (prop === "id") return { name, toString: () => hex(`${binding}\u0000${name}`, 64) }
        return async (...args: Array<unknown>) => {
          const o = await this.object(binding, name)
          const fn = o.instance[prop]
          if (typeof fn !== "function") throw new TypeError(`${this.classes.get(binding)?.className}.${prop} is not a method`)
          return copy(await (fn as (...a: Array<unknown>) => unknown).apply(o.instance, args.map(copy)))
        }
      }
    })
  }

  /** The live object `binding`/`name`, made (and its start gate passed) on first use. */
  async object(binding: string, name: string): Promise<LiveObject> {
    if (this.stopped) throw new Error("runtime stopped")
    const key = `${binding}\u0000${name}`
    let o = this.live.get(key)
    if (!o) {
      const cls = this.classes.get(binding)
      if (!cls) throw new Error(`no class bound as ${binding}`)
      const dir = join(this.dataDir, "do", cls.className)
      mkdirSync(dir, { recursive: true })
      const storage = new ObjectStorage(join(dir, `${hex(key)}.sqlite`))
      const id: ObjectId = { name, toString: () => hex(key, 64), equals: (x) => x.toString() === hex(key, 64) }
      const state = new ObjectState(id, storage)
      this.index.prepare("INSERT OR IGNORE INTO objects (binding, name) VALUES (?, ?)").run(binding, name)
      const instance = new cls.ctor(state as never, this.env as never) as LiveObject["instance"]
      const live: LiveObject = { instance, state, ready: state.ready(), retry: 0 }
      this.live.set(key, live)
      storage.onAlarmChange((at) => this.arm(live, at))
      o = live
      this.arm(live, storage.alarmAt())
    }
    await o.ready
    return o
  }

  /** Makes every object that has a stored alarm, so its timer runs again after a restart. */
  async rearmAlarms(): Promise<number> {
    const rows = this.index.query("SELECT binding, name FROM objects").all() as Array<{ binding: string; name: string }>
    let n = 0
    for (const r of rows) {
      if (!this.classes.has(r.binding)) continue
      const cls = this.classes.get(r.binding)!
      const file = join(this.dataDir, "do", cls.className, `${hex(`${r.binding}\u0000${r.name}`)}.sqlite`)
      const probe = new ObjectStorage(file)
      const at = probe.alarmAt()
      probe.close()
      if (at !== null) [await this.object(r.binding, r.name), n++]
    }
    return n
  }

  private arm(o: LiveObject, at: number | null): void {
    if (o.timer) clearTimeout(o.timer)
    o.timer = undefined
    if (at === null || this.stopped) return
    const delay = Math.min(Math.max(0, at - Date.now()), MAX_TIMER_MS)
    // One timer per object for its one alarm: the intended deadline, cancelled when the alarm moves.
    o.timer = setTimeout(() => void this.fire(o, at), delay)
  }

  private async fire(o: LiveObject, at: number): Promise<void> {
    o.timer = undefined
    if (Date.now() < at) return this.arm(o, at)
    // The alarm is cleared before it runs; the handler may set the next one.
    if (o.state.storage.alarmAt() === at) o.state.storage.sql.exec("DELETE FROM _cf_alarm WHERE id = 1")
    try {
      await o.instance.alarm?.({ retryCount: o.retry, isRetry: o.retry > 0 })
      o.retry = 0
    } catch (e) {
      console.error(JSON.stringify({ msg: "alarm threw", object: o.state.id.name, retry: o.retry, error: String(e).slice(0, 300) }))
      if (o.retry < ALARM_RETRIES && o.state.storage.alarmAt() === null) {
        o.retry++
        await o.state.storage.setAlarm(Date.now() + 2 ** o.retry * 1000)
      } else o.retry = 0
    }
  }

  /** Whether `stop` ran (late socket events after shutdown are dropped). */
  get isStopped(): boolean {
    return this.stopped
  }

  /** Every live object's state (sockets, background work), for the router and tests. */
  states(): Array<ObjectState> {
    return [...this.live.values()].map((o) => o.state)
  }

  /** Waits for every object's background work (tests). */
  async idle(): Promise<void> {
    for (const s of this.states()) await s.idle()
  }

  /**
   * Runs every alarm that is due now, and the alarms those set for now, until none is due and no
   * background work is left (tests read projections such as the inbox after the outbox drained).
   */
  async quiesce(maxRounds = 50): Promise<void> {
    for (let round = 0; round < maxRounds; round++) {
      await this.idle()
      const due = [...this.live.values()].filter((o) => {
        const at = o.state.storage.alarmAt()
        return at !== null && at <= Date.now()
      })
      if (due.length === 0) return
      for (const o of due) {
        if (o.timer) clearTimeout(o.timer)
        await this.fire(o, o.state.storage.alarmAt()!)
      }
    }
  }

  /** Stops timers and closes files. */
  stop(): void {
    this.stopped = true
    for (const o of this.live.values()) {
      if (o.timer) clearTimeout(o.timer)
      o.state.storage.close()
    }
    this.live.clear()
    this.index.close()
  }
}
