import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { apply, create, LOCAL_REJECT_CODES, REJECT_CODES, type ConversationHead, type CreateRequest, type OpRequest, type OpKind } from "../src/conversation/index.ts"

/**
 * Runs the shared corpus (conformance/*.json) against the TypeScript core.
 * The Rust crate `cmux-conversation` runs the same files (cargo test on a
 * testbox); see the notes inside each file for the runner contract.
 */
interface CorpusCase {
  readonly name: string
  readonly head?: ConversationHead
  readonly request?: OpRequest
  readonly create?: CreateRequest
  readonly expect: { readonly commit?: unknown; readonly head?: unknown; readonly reject?: string }
}

const load = (file: string): ReadonlyArray<CorpusCase> => {
  const body = JSON.parse(readFileSync(new URL(`../conformance/${file}`, import.meta.url), "utf8")) as { format: string; cases: Array<CorpusCase> }
  expect(body.format).toBe("cmux-conversation-conformance/1")
  return body.cases
}

const outcome = (c: CorpusCase): unknown => {
  if (c.create) {
    const result = create(c.create)
    return result.ok ? { head: result.head } : { reject: result.code }
  }
  const result = apply(c.head!, c.request!)
  return result.ok ? { commit: result.commit } : { reject: result.code }
}

const LOCAL_OPS: ReadonlyArray<OpKind> = [
  "message.send",
  "message.edit",
  "message.retract",
  "reaction.add",
  "reaction.remove",
  "read_cursor.set",
  "participants.add",
  "title.set",
  "question.answer"
]

describe.each([
  ["conversation-cases.json", "local"],
  ["conversation-cloud-cases.json", "cloud"]
] as const)("conformance corpus %s", (file, mode) => {
  const cases = load(file)

  it("has unique names and enough cases", () => {
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length)
    expect(cases.length).toBeGreaterThanOrEqual(30)
  })

  it.each(cases.map((c) => [c.name, c] as const))("%s", (_name, c) => {
    expect(JSON.parse(JSON.stringify(outcome(c)))).toEqual(c.expect)
  })

  if (mode === "local") {
    it("covers every local op and stays inside the Rust crate's vocabulary", () => {
      const ops = new Set(cases.flatMap((c) => (c.request ? [c.request.op.kind] : [])))
      for (const op of LOCAL_OPS) expect(ops, op).toContain(op)
      for (const c of cases) {
        expect(c.head?.kind, c.name).toBeUndefined()
        if (c.request) expect(LOCAL_OPS, c.name).toContain(c.request.op.kind)
        if (c.expect.reject) expect(LOCAL_REJECT_CODES, c.name).toContain(c.expect.reject)
      }
      expect(cases.some((c) => c.create)).toBe(true)
    })
  } else {
    it("covers every cloud op", () => {
      const ops = new Set(cases.flatMap((c) => (c.request ? [c.request.op.kind] : [])))
      for (const op of ["participants.remove", "invite.create", "invite.revoke", "invite.accept", "invite.approve_join", "invite.delivery.report", "conversation.settings.set"]) {
        expect(ops, op).toContain(op)
      }
      for (const c of cases) if (c.expect.reject) expect(REJECT_CODES, c.name).toContain(c.expect.reject)
    })
  }
})
