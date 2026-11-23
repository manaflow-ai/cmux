import { env } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { vi } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * Shared by the Auto mode tests (src/auto-sessions): the clock, the callers, and the fake of the platform's Cloud
 * machine. Time moves only when a test says so (`advance`), then the object's alarm is run by hand (`fireAlarm`):
 * no test sleeps to let a lease run out.
 */
export const runIn = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
export const testEnv = env as unknown as { AUTO_SESSION_DO: DurableObjectNamespace; AUTO_SESSION_INDEX_DO: DurableObjectNamespace; USER_DO: DurableObjectNamespace }

/** The machine every test uses as the owner's Auto machine, and another of the same owner. */
export const M = `vm_${"a".repeat(20)}`
export const M2 = `vm_${"b".repeat(20)}`

let ahead = 0
const real = Date.now.bind(Date)
/** Puts every `Date.now()` of the Worker and its objects `ahead` of the real clock. Call once per file. */
export const fakeClock = (): void => void vi.spyOn(Date, "now").mockImplementation(() => real() + ahead)
export const advance = (ms: number): void => void (ahead += ms)

export const as = (t: string) => ({ authorization: `Bearer ${t}` })
export const call = async (method: string, path: string, headers: Record<string, string> = {}, body?: unknown) => {
  const r = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  const text = await r.text()
  return { status: r.status, body: (text ? JSON.parse(text) : null) as any }
}

export type Person = Awaited<ReturnType<typeof signedInWithInstall>>
export const person = (name: string): Promise<Person> => signedInWithInstall(`auto-${name}`, "cli")

/** The bearer of a VM install bound to `machine`, registered on the person's UserDO as the Cloud's bind registers it. */
export const vmBearer = async (a: Person, machine: string): Promise<string> => {
  const id = `inst_vm${crypto.randomUUID().replace(/-/g, "").slice(0, 18)}`
  const grant = `grant_${crypto.randomUUID().replace(/-/g, "").slice(0, 20)}`
  await runIn(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(a.user)), async (i) => {
    const s = i.boundEngine.currentState
    s.installs[id] = { ...s.installs[a.install], id, kind: "vm", grant, revoked_at: null, bound_team: a.team, bound_machine: machine }
    s.grants[grant] = { id: grant, grantee: id, op_classes: ["vm-self"], approval: "none", expires_at: null, revoked_at: null, created_from: "install" }
  })
  return (await mintAccessToken(testEnv as any, { user: a.user, team: a.team, install: id, grant, vm: true })).token
}

export const chatStub = (owner: string, id: string) => testEnv.AUTO_SESSION_DO.get(testEnv.AUTO_SESSION_DO.idFromName(`${owner}/${id}`))
export const indexStub = (owner: string) => testEnv.AUTO_SESSION_INDEX_DO.get(testEnv.AUTO_SESSION_INDEX_DO.idFromName(owner))

/** The platform's Cloud machine, as the store sees it: what a read answers, and the starts it was asked for. */
export type FakeMachine = { status: string; revision: string; reads: number; starts: Array<string>; failStart: boolean; failRead: boolean }
/** Puts a fake Cloud behind the owner's index object (the platform's CloudDO is not in this Worker). */
export const fakeCloud = async (owner: string): Promise<FakeMachine> => {
  const m: FakeMachine = { status: "paused", revision: "rev1", reads: 0, starts: [], failStart: false, failRead: false }
  const cloud = {
    readOp: async () => {
      m.reads += 1
      return m.failRead ? { ok: false, code: "owner.unreachable", message: "down" } : { ok: true, revision: m.revision, value: { machine: { status: m.status } } }
    },
    submit: async (_team: string, _p: unknown, frame: { idempotency_key: string }) => {
      if (m.failStart) return { frames: [{ t: "reject", code: "cloud.capacity" }] }
      m.starts.push(frame.idempotency_key)
      m.status = "starting"
      return { frames: [{ t: "result" }] }
    }
  }
  await runIn(indexStub(owner), async (instance) => void (instance.env = { ...instance.env, CLOUD_DO: { idFromName: (x: string) => x, get: () => cloud } }))
  return m
}
export const starts = (owner: string) => runIn(indexStub(owner), async (_i, state) => state.storage.sql.exec(`SELECT * FROM starts`).toArray() as Array<Record<string, number | string>>)

export const setMachine = (a: Person, machine = M) => call("PUT", "/v1/auto-sessions/machine", as(a.session), { team: a.team, machine })
export const open = (t: string, id: string, more: Record<string, unknown> = {}) => call("PUT", `/v1/auto-sessions/${id}`, as(t), { auto: true, title: "Fix the flaky test", harness: "claude", device: "mac1", ...more })
export const get = (t: string, id: string) => call("GET", `/v1/auto-sessions/${id}`, as(t))
export const lease = (t: string, id: string, holder: string, epoch: number, more: Record<string, unknown> = { needsRun: false }) => call("POST", `/v1/auto-sessions/${id}/lease`, as(t), { holder, epoch, ...more })
export const post = (t: string, id: string, sub: string, body: unknown) => call("POST", `/v1/auto-sessions/${id}/${sub}`, as(t), body)
export const LAPTOP = "device:mac1"
export const VM = `vm:${M}`

/** The laptop's lease runs out: the clock passes it and the chat's alarm runs. */
export const lapse = async (owner: string, id: string): Promise<void> => {
  advance(46_000)
  await fireAlarm(chatStub(owner, id))
}
/** A chat its laptop left with a turn running: the Auto machine holds it at epoch 2 with a `takeover` to pick up. */
export const takenOver = async (a: Person, id: string): Promise<void> => {
  await open(a.session, id)
  await lease(a.session, id, LAPTOP, 1, { needsRun: true })
  await lapse(a.user, id)
}

export const sha256 = async (bytes: Uint8Array): Promise<string> => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)))].map((b) => b.toString(16).padStart(2, "0")).join("")
export const putChunk = async (t: string, id: string, sha: string, bytes: Uint8Array, holder: string, epoch: number) => {
  const r = await worker.fetch(`https://api.test/v1/auto-sessions/${id}/chunks/${sha}`, { method: "PUT", headers: { ...as(t), "x-cmux-auto-holder": holder, "x-cmux-auto-epoch": String(epoch) }, body: new Uint8Array(bytes) })
  const text = await r.text()
  return { status: r.status, body: (text ? JSON.parse(text) : null) as any }
}
export const getChunk = async (t: string, id: string, sha: string) => {
  const r = await worker.fetch(`https://api.test/v1/auto-sessions/${id}/chunks/${sha}`, { headers: as(t) })
  return { status: r.status, bytes: new Uint8Array(await r.arrayBuffer()) }
}
