/**
 * What Cloud Chief D's model sees in one request (plans/cmux-next/cloud-chief-durable-DESIGN.md
 * section 3): pi's system entries, then the run's memory view in place of the run's first input, then
 * the run's later messages and tool rounds. Everything pi kept from earlier runs is dropped.
 *
 * Each batch D submits starts with a marker line (`batchMarker`), so the request can be cut at the
 * run's first batch without any id on pi's messages. Batches already inside the view are dropped
 * where pi placed them; the markers of later batches are removed before the model sees them.
 */
const MARK = /^⟦d:(\d+)⟧\n?/

/** The first line of batch `n`'s input. */
export const batchMarker = (n: number): string => `⟦d:${n}⟧\n`

type Part = { readonly type: string; readonly text?: string }
type Msg = { readonly role: string; readonly content?: unknown }

const parts = (m: Msg): ReadonlyArray<Part> => (Array.isArray(m.content) ? (m.content as ReadonlyArray<Part>) : typeof m.content === "string" ? [{ type: "text", text: m.content }] : [])

/** The batch number a user message starts with, or null. */
export const batchOf = (m: Msg): number | null => {
  if (m.role !== "user") return null
  const first = parts(m).find((p) => p.type === "text")
  const hit = first?.text ? MARK.exec(first.text) : null
  return hit ? Number(hit[1]) : null
}

const unmark = <M extends Msg>(m: M): M => {
  const ps = parts(m)
  const i = ps.findIndex((p) => p.type === "text")
  if (i < 0) return m
  const text = (ps[i]!.text ?? "").replace(MARK, "")
  return { ...m, content: ps.map((p, j) => (j === i ? { ...p, text } : p)).filter((p) => p.type !== "text" || (p.text ?? "").length > 0) }
}

/**
 * The request for run `first` (its first batch number), whose view holds `covered` batches.
 * Returns null when the run's first batch is not in `messages` (pi did not place it yet): the
 * caller then sends pi's request unchanged.
 */
export const runRequest = <M extends Msg>(messages: ReadonlyArray<M>, run: { readonly first: number; readonly covered: ReadonlyArray<number>; readonly view: ReadonlyArray<string> }): Array<M> | null => {
  const start = messages.findIndex((m) => batchOf(m) === run.first)
  if (start < 0) return null
  const covered = new Set(run.covered)
  const system = messages.filter((m) => m.role === "system")
  const head = { ...messages[start]!, content: run.view.filter((t) => t.trim().length > 0).map((text) => ({ type: "text", text })) } as M
  const rest = messages.slice(start + 1).filter((m) => m.role !== "system" && !(batchOf(m) !== null && covered.has(batchOf(m)!)))
  return [...system, head, ...rest.map(unmark)]
}
