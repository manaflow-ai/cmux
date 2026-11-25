import { exportPKCS8, generateKeyPair } from "jose"
import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, describe, expect, it, vi } from "vitest"
import { env } from "cloudflare:workers"
import worker from "../src/index.ts"
import { call, register, token } from "./helpers.ts"

// Push-latency probe (optimum-ledger row 16), the half a device is not needed for: a Mac's POST
// /v1/devices/{mac}/notify arriving at the Worker -> the push handed to APNs (cmuxSentAtMs, the probe's own
// stamp, push.ts sendApns) -> the Worker's answer. APNs is a mock answering 200 at once, so APNs's own time
// and the APNs -> phone leg are not in it. workerd's clock only moves across I/O (D1, the user hub, fetch),
// so each number is at I/O granularity. NOTIFY_LIMIT is off here so the runs are not rate limited.
// Prints one PUSHHOP line per load: idle (one phone, one notify at a time) and duress (25 phones, 8
// notifies at once).

const pushToken = (i: number) => (i + 1).toString(16).padStart(64, "0")
const RUNS = 30

afterEach(() => vi.restoreAllMocks())

const person = async (name: string, count: number) => {
  const t = await token(name)
  const mac = await register(t, "mac", `personal-${name}`)
  for (let i = 0; i < count; i++) {
    const phone = await register(t, "phone", `personal-${name}`)
    const r = await call("PUT", `/v1/devices/${phone}/push`, t, { token: pushToken(i), environment: "production", topic: "dev.cmux.mobile", kinds: ["question"] })
    expect(r.status).toBe(200)
  }
  return { t, mac }
}

const rig = async () => {
  const { privateKey } = await generateKeyPair("ES256", { extractable: true })
  const benchEnv = { ...env, APNS_KEY_P8: await exportPKCS8(privateKey), APNS_KEY_ID: "KEY123", APNS_TEAM_ID: "TEAM123", PUSH_SENT_AT_PROBE: "1", NOTIFY_LIMIT: undefined }
  const stamps = new Map<string, number>()
  const realFetch = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const req = input instanceof Request ? input : new Request(String(input), init)
    if (req.url.startsWith("https://api.push.apple.com/3/device/")) {
      const body = (await req.json()) as { cmuxSentAtMs?: number; cmuxMobile?: { eventId?: string } }
      const id = body.cmuxMobile?.eventId
      if (id && typeof body.cmuxSentAtMs === "number" && !stamps.has(id)) stamps.set(id, body.cmuxSentAtMs)
      return new Response(null, { status: 200 })
    }
    return realFetch(input, init)
  })
  /** One notify: [arrive -> APNs hand-off, arrive -> answer] in ms. */
  const notify = async (t: string, mac: string, eventId: string): Promise<[number, number]> => {
    const ctx = createExecutionContext()
    const start = Date.now()
    const res = await worker.fetch(
      new Request(`https://api.test/v1/devices/${mac}/notify`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify({ eventId, kind: "question", agent: "Claude", place: "repo" }) }),
      benchEnv as unknown as Parameters<typeof worker.fetch>[1],
      ctx
    )
    await res.text()
    const done = Date.now()
    await waitOnExecutionContext(ctx)
    expect(res.status).toBe(200)
    const sent = stamps.get(eventId)
    expect(sent).toBeTypeOf("number")
    return [sent! - start, done - start]
  }
  return { notify }
}

const pct = (xs: number[], p: number) => {
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]!
}

const line = (load: string, phones: number, conc: number, samples: Array<[number, number]>) => {
  const hand = samples.map((s) => s[0])
  const answer = samples.map((s) => s[1])
  console.log(
    `PUSHHOP flow=push pair=ios-mac hop=notify_to_apns_handoff load=${load} phones=${phones} concurrency=${conc} n=${samples.length} ` +
      `handoff_p50_ms=${pct(hand, 50)} handoff_p95_ms=${pct(hand, 95)} handoff_max_ms=${Math.max(...hand)} ` +
      `answer_p50_ms=${pct(answer, 50)} answer_p95_ms=${pct(answer, 95)} apns=mock clock=workerd-io-granular`
  )
}

describe("push hop bench: notify -> APNs hand-off", () => {
  it("idle: one phone, one notify at a time", async () => {
    const { t, mac } = await person("hopidle", 1)
    const { notify } = await rig()
    await notify(t, mac, "warm-idle")
    const samples: Array<[number, number]> = []
    for (let i = 0; i < RUNS; i++) samples.push(await notify(t, mac, `idle-${i}`))
    line("idle", 1, 1, samples)
  }, 120_000)

  it("duress: 25 phones, 8 notifies at once", async () => {
    const { t, mac } = await person("hopduress", 25)
    const { notify } = await rig()
    await notify(t, mac, "warm-duress")
    const samples: Array<[number, number]> = []
    for (let r = 0; r < RUNS / 6; r++) samples.push(...(await Promise.all(Array.from({ length: 8 }, (_, i) => notify(t, mac, `duress-${r}-${i}`)))))
    line("duress", 25, 8, samples)
  }, 120_000)
})
