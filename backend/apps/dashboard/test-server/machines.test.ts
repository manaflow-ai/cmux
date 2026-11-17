/**
 * The Machines page's API exchange (#44784: wake a paused machine without a Mac), replayed
 * against the protocol's committed wire vectors (backend/catalog/cloud-vectors.json): the same
 * `cloud.machine.list` pages and `cloud.machine.start` answers the Cloud API sends, including a
 * start from a signed-in browser session. A fake API answers each request with its vector's body
 * and records what the page sent.
 */
import { expect, test } from "bun:test"
import vectors from "../../../catalog/cloud-vectors.json"
import { canStart, loadMachines, MachinesError, startMachine, type MachineRow } from "../src/lib/machines"
import { machinesErrorText } from "../src/lib/machines-strings"

interface Vector {
  readonly name: string
  readonly op: string
  readonly principal: { readonly kind: string }
  readonly params: Record<string, unknown>
  readonly idempotency_key?: string
  readonly responses: ReadonlyArray<{ readonly http: { readonly path: string; readonly status: number }; readonly body: unknown }>
}

const cases = (vectors as unknown as { cases: ReadonlyArray<Vector> }).cases
const vector = (name: string): Vector => {
  const found = cases.find((c) => c.name === name)
  if (!found) throw new Error(`no wire vector ${name}`)
  return found
}
const answer = (v: Vector) => ({ status: v.responses[0]!.http.status, body: v.responses[0]!.body })

test("the list reads every page, following next_cursor, and shows the paused machine", async () => {
  const first = vector("machine.list.first_page")
  const second = vector("machine.list.second_page")
  const sent: Array<[string, Record<string, unknown>]> = []
  const rows = await loadMachines(async (op, params) => {
    sent.push([op, params])
    return answer(params.cursor === second.params.cursor ? second : first)
  })
  expect(sent).toEqual([
    ["cloud.machine.list", { limit: 100 }],
    ["cloud.machine.list", { limit: 100, cursor: "cur_page2" }]
  ])
  // Running first (newest first), then paused.
  expect(rows.map((r) => [r.id, r.status])).toEqual([
    ["vm_m0000000000000000003", "running"],
    ["vm_m0000000000000000001", "running"],
    ["vm_m0000000000000000002", "paused"]
  ])
  expect(rows.filter(canStart).map((r) => r.id)).toEqual(["vm_m0000000000000000002"])
})

test("a signed-out read is the API's auth.unauthenticated, so the page asks to sign in again", async () => {
  const error = await loadMachines(async () => answer(vector("machine.list.unauthenticated"))).catch((e: unknown) => e)
  expect(error).toBeInstanceOf(MachinesError)
  expect([(error as MachinesError).code, (error as MachinesError).status]).toEqual(["auth.unauthenticated", 401])
})

const pausedRow = async (): Promise<MachineRow> => {
  const rows = await loadMachines(async () => answer(vector("machine.list.default")))
  return rows.find((r) => r.status === "paused")!
}

test("Start sends cloud.machine.start for the paused machine as a session may, and the API accepts it", async () => {
  const start = vector("machine.start")
  // The vector is a browser session's call: the dashboard's principal.
  expect(start.principal.kind).toBe("session")
  const sent: Array<[string, Record<string, unknown>, string]> = []
  const outcome = await startMachine(
    async (op, params, key) => {
      sent.push([op, params, key])
      return answer(start)
    },
    await pausedRow(),
    "dash:key-1"
  )
  expect(sent).toEqual([[start.op, start.params, "dash:key-1"]])
  expect(outcome).toEqual({ ok: true })
})

test("a refused start keeps the API's code and the page explains it", async () => {
  const quota = await startMachine(async () => answer(vector("machine.start.quota")), await pausedRow(), "dash:key-2")
  expect(quota).toEqual({ ok: false, code: "cloud.quota.exceeded", status: 200 })
  expect(machinesErrorText("en", "cloud.quota.exceeded")).toBe("You're at your plan's limit of running machines. Pause one first.")

  const raced = await startMachine(async () => answer(vector("machine.start.not_paused")), await pausedRow(), "dash:key-3")
  expect(raced).toEqual({ ok: false, code: "cloud.machine.not_paused", status: 200 })
  expect(machinesErrorText("ja", "cloud.machine.not_paused")).toBe("このマシンはもう一時停止していません。一覧を更新してください。")
})

test("only a paused machine offers Start, and Start never calls the API for any other", async () => {
  const rows = await loadMachines(async () => answer(vector("machine.list.default")))
  const running = rows.find((r) => r.status === "running")!
  let calls = 0
  const outcome = await startMachine(
    async () => {
      calls += 1
      return answer(vector("machine.start"))
    },
    running,
    "dash:key-4"
  )
  expect(calls).toBe(0)
  expect(outcome.ok).toBe(false)
  for (const status of ["provisioning", "starting", "running", "pausing", "deleting", "failed"] as const) {
    expect(canStart({ status })).toBe(false)
  }
})

test("every error code the start op declares has its own sentence in both languages", () => {
  const generic = machinesErrorText("en", "unknown")
  for (const code of [
    "cloud.machine.not_found",
    "cloud.machine.not_paused",
    "cloud.machine.not_bound",
    "cloud.quota.exceeded",
    "cloud.plan.required",
    "cloud.spend_cap.reached",
    "cloud.member_budget.reached",
    "cloud.quota.vm_limit",
    "cloud.rate_limited",
    "cloud.provider.unavailable",
    "mutation.indeterminate",
    "auth.unauthenticated",
    "auth.forbidden"
  ]) {
    expect(machinesErrorText("en", code)).not.toBe(generic)
    expect(machinesErrorText("ja", code)).not.toBe(machinesErrorText("ja", "unknown"))
  }
})
