/**
 * Per-request timing (PROTOCOL.md "Server-Timing"): each step a request waits on (token check, Stack,
 * database, Durable Object, TURN) is a span; the response carries them as a `Server-Timing` header and
 * the log records them. Workers clocks advance only across I/O, which is exactly what is measured here.
 */
export class Timing {
  private readonly spans: Array<{ name: string; ms: number }> = []
  private readonly started = Date.now()

  /** Awaits `work` and records how long it took under `name` (repeated names add up). */
  async span<T>(name: string, work: PromiseLike<T>): Promise<T> {
    const start = Date.now()
    try {
      // Only awaited: a Durable Object RPC result is a callable thenable, never call it.
      return await work
    } finally {
      this.add(name, Date.now() - start)
    }
  }

  add(name: string, ms: number) {
    const hit = this.spans.find((s) => s.name === name)
    if (hit) hit.ms += ms
    else this.spans.push({ name, ms })
  }

  get totalMs(): number {
    return Date.now() - this.started
  }

  /** `auth;dur=3, db;dur=81, total;dur=90` */
  header(): string {
    return [...this.spans, { name: "total", ms: this.totalMs }].map((s) => `${s.name};dur=${s.ms}`).join(", ")
  }

  record(): Record<string, number> {
    return Object.fromEntries([...this.spans.map((s) => [s.name, s.ms] as const), ["total", this.totalMs] as const])
  }
}

/** The timing of the request a given ExecutionContext belongs to (one per request). */
const byContext = new WeakMap<object, Timing>()
export const timingFor = (ctx: object): Timing => {
  let t = byContext.get(ctx)
  if (!t) {
    t = new Timing()
    byContext.set(ctx, t)
  }
  return t
}
