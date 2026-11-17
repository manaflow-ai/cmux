/**
 * The Machines page (#44784): the team's Cloud machines from `cloud.machine.list`, and Start on a
 * paused one (`cloud.machine.start`), so a person can wake a machine from a browser without the
 * Mac app. The same ops the Mac's Machines section and the phone's Cloud Machines page call
 * (packages/protocol/src/cloud-machine-ops.ts); this module holds no API code of its own.
 */

export type MachineStatus = "provisioning" | "starting" | "running" | "pausing" | "paused" | "deleting" | "failed"

const STATUSES: ReadonlySet<string> = new Set<MachineStatus>(["provisioning", "starting", "running", "pausing", "paused", "deleting", "failed"])

export type PauseReason = "idle" | "no_report" | "provider_stopped" | "provider_paused"

/** The part of a `cloud.machine.list` item the page reads. */
export interface MachineRow {
  readonly id: string
  readonly name: string | null
  readonly status: MachineStatus
  readonly pauseReason: PauseReason | null
  readonly error: string | null
  readonly createdAt: number | null
}

/** One read the page sends: the dashboard's `read` server function, scoped to the URL's team. */
export type ReadOp = (op: string, params: Record<string, unknown>) => Promise<{ readonly status: number; readonly body: unknown }>

/** One op the page sends: the dashboard's `mutate` server function (POST /v1/ops), scoped to the URL's team. */
export type MutateOp = (op: string, params: Record<string, unknown>, idempotencyKey: string) => Promise<{ readonly status: number; readonly body: unknown }>

/** A refused read or op, by its API error code (`auth.unauthenticated`, `cloud.plan.required`...). */
export class MachinesError extends Error {
  constructor(
    readonly code: string,
    readonly status: number
  ) {
    super(code)
  }
}

/** Pages the list reads at most (100 machines a page): the same bound the phone uses. */
export const MAX_PAGES = 10

const record = (v: unknown): Record<string, unknown> | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null)

const PAUSE_REASONS: ReadonlySet<string> = new Set<PauseReason>(["idle", "no_report", "provider_stopped", "provider_paused"])

/** One list item, or null for an item the page cannot show (an unknown status is a newer API: skip it). */
export const parseMachine = (item: unknown): MachineRow | null => {
  const m = record(item)
  if (!m || typeof m.id !== "string" || typeof m.status !== "string" || !STATUSES.has(m.status)) return null
  const error = record(m.error)
  return {
    id: m.id,
    name: typeof m.name === "string" && m.name ? m.name : null,
    status: m.status as MachineStatus,
    pauseReason: typeof m.pause_reason === "string" && PAUSE_REASONS.has(m.pause_reason) ? (m.pause_reason as PauseReason) : null,
    error: error && typeof error.message === "string" ? error.message : null,
    createdAt: typeof m.created_at === "number" ? m.created_at : null
  }
}

/**
 * The API's error code in a refused answer: an op's `{ok: false, error: {code}}`, or an HTTP
 * refusal's top-level `{code}` (`{_tag: "Unauthenticated", code: "auth.unauthenticated"}`).
 */
export const errorCode = (status: number, body: unknown): string => {
  const b = record(body)
  const code = record(b?.error)?.code ?? b?.code
  if (typeof code === "string" && code) return code
  return status === 401 ? "auth.unauthenticated" : "unknown"
}

/** Running first, then the ones changing, then paused, then failed; newest first inside each. */
const RANK: Record<MachineStatus, number> = { running: 0, starting: 1, provisioning: 1, pausing: 2, paused: 3, failed: 4, deleting: 5 }

export const sortMachines = (rows: ReadonlyArray<MachineRow>): Array<MachineRow> =>
  [...rows].sort((a, b) => RANK[a.status] - RANK[b.status] || (b.createdAt ?? 0) - (a.createdAt ?? 0))

/** Every machine of the team: `cloud.machine.list` page by page, following `next_cursor`. */
export const loadMachines = async (read: ReadOp): Promise<Array<MachineRow>> => {
  const rows: Array<MachineRow> = []
  let cursor: string | null = null
  for (let page = 0; page < MAX_PAGES; page++) {
    const r = await read("cloud.machine.list", cursor ? { limit: 100, cursor } : { limit: 100 })
    if (r.status !== 200) throw new MachinesError(errorCode(r.status, r.body), r.status)
    const value = record(record(r.body)?.value)
    const items = Array.isArray(value?.machines) ? value.machines : []
    for (const item of items) {
      const row = parseMachine(item)
      if (row) rows.push(row)
    }
    cursor = typeof value?.next_cursor === "string" && value.next_cursor ? value.next_cursor : null
    if (!cursor) break
  }
  return sortMachines(rows)
}

/** Only a paused machine can be started; the API answers cloud.machine.not_paused for any other. */
export const canStart = (m: Pick<MachineRow, "status">): boolean => m.status === "paused"

/** The op Start sends for this machine, or null when it may not be sent. */
export const startRequest = (m: MachineRow): { readonly op: "cloud.machine.start"; readonly params: { readonly machine: string } } | null =>
  canStart(m) ? { op: "cloud.machine.start", params: { machine: m.id } } : null

/** A change the next list settles: the page offers Refresh instead of reading again on a timer. */
export const isTransition = (m: Pick<MachineRow, "status">): boolean =>
  m.status === "provisioning" || m.status === "starting" || m.status === "pausing" || m.status === "deleting"

/** What Start came to: accepted (the machine is starting), or refused with the API's error code. */
export type StartOutcome = { readonly ok: true } | { readonly ok: false; readonly code: string; readonly status: number }

/**
 * Start a paused machine: `cloud.machine.start {machine}` with a fresh idempotency key. An op the
 * API refused answers HTTP 200 with `ok: false`; a refused request (401, 403...) answers its status.
 */
export const startMachine = async (mutate: MutateOp, machine: MachineRow, idempotencyKey: string): Promise<StartOutcome> => {
  const request = startRequest(machine)
  if (!request) return { ok: false, code: "cloud.machine.not_paused", status: 0 }
  const r = await mutate(request.op, request.params, idempotencyKey)
  if (r.status === 200 && record(r.body)?.ok === true) return { ok: true }
  return { ok: false, code: errorCode(r.status, r.body), status: r.status }
}
