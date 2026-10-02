import { Exit, Schema } from "effect"
import { checkSubsetSchema, checkSubsetValue, type SubsetResult } from "./feed-schema-subset.ts"
import { OpClass } from "./schemas.ts"

/**
 * The feed kind registry (plans/cmux-next/feed.md 3.4): each built-in kind has
 * a prompt schema, an answer schema and semantic checks that tie the answer to
 * the prompt. Custom kinds (`x-<publisher>.<name>`) carry their own
 * `answer_schema` (the JSON Schema subset). Pure: owners and mirrors call it.
 */

const Text = (max: number) => Schema.String.check(Schema.isMaxLength(max))
const NonEmpty = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))
const Int = (minimum: number, maximum: number) => Schema.Int.check(Schema.isBetween({ minimum, maximum }))
const List = <S extends Schema.Top>(item: S, min: number, max: number) => Schema.Array(item).check(Schema.isMinLength(min), Schema.isMaxLength(max))

export const MAX_FILE_BYTES = 50 * 1024 * 1024

export const FeedAttachment = Schema.Struct({
  id: NonEmpty(64),
  name: NonEmpty(200),
  mime: NonEmpty(100),
  size: Int(0, MAX_FILE_BYTES),
  sha256: Schema.String.check(Schema.isPattern(/^[a-f0-9]{64}$/)),
  /** Where the bytes are: an R2 key (cloud) or a local store key; never a URL with credentials. */
  ref: NonEmpty(512)
}).annotate({ identifier: "FeedAttachment", description: "A file attached to a feed item or an answer." })

const ApproveScope = Schema.Literals(["once", "session", "always"])

const ChoiceQuestion = Schema.Struct({
  id: NonEmpty(40),
  question: NonEmpty(1000),
  header: Schema.optionalKey(Text(40)),
  options: List(Schema.Struct({ id: NonEmpty(40), label: NonEmpty(200), description: Schema.optionalKey(Text(1000)) }), 2, 8),
  multi: Schema.Boolean,
  allow_other: Schema.Boolean
})

interface KindDef {
  readonly prompt: Schema.Top
  readonly answer: Schema.Top
  readonly priority: "low" | "normal" | "high" | "urgent"
  /** Only a Mac (the browser pane or terminal that holds the context) can answer. */
  readonly needsMac: boolean
  /** Semantic checks of a decoded prompt (beyond the schema). */
  readonly checkPrompt?: (prompt: any) => SubsetResult
  /** Semantic checks of a decoded answer against its decoded prompt. */
  readonly checkAnswer?: (prompt: any, answer: any) => SubsetResult
  readonly docs: string
}

const ok: SubsetResult = { ok: true }
const fail = (message: string): SubsetResult => ({ ok: false, message })

const browserStatus = (values: ReadonlyArray<string>) => Schema.Struct({ status: Schema.Literals(values as [string, ...Array<string>]) })

export const feedKinds: Readonly<Record<string, KindDef>> = {
  question: {
    prompt: Schema.Struct({ question: NonEmpty(2000), suggestions: Schema.optionalKey(List(NonEmpty(200), 0, 8)), multiline: Schema.optionalKey(Schema.Boolean) }),
    answer: Schema.Struct({ text: NonEmpty(16_000) }),
    priority: "high",
    needsMac: false,
    docs: "A free-text question."
  },
  choice: {
    prompt: Schema.Struct({ questions: List(ChoiceQuestion, 1, 4) }),
    answer: Schema.Struct({ answers: Schema.Record(Schema.String, Schema.Struct({ selected: List(NonEmpty(40), 0, 8), other: Schema.optionalKey(NonEmpty(2000)) })) }),
    priority: "high",
    needsMac: false,
    checkPrompt: (p: { questions: ReadonlyArray<{ id: string; options: ReadonlyArray<{ id: string }> }> }) => {
      if (new Set(p.questions.map((q) => q.id)).size !== p.questions.length) return fail("question ids must be unique")
      for (const q of p.questions) if (new Set(q.options.map((o) => o.id)).size !== q.options.length) return fail(`option ids of ${q.id} must be unique`)
      return ok
    },
    checkAnswer: (p: { questions: ReadonlyArray<typeof ChoiceQuestion.Type> }, a: { answers: Record<string, { selected: ReadonlyArray<string>; other?: string }> }) => {
      for (const id of Object.keys(a.answers)) if (!p.questions.some((q) => q.id === id)) return fail(`unknown question ${id}`)
      for (const q of p.questions) {
        const r = a.answers[q.id]
        if (!r) return fail(`question ${q.id} has no answer`)
        if (r.other !== undefined && !q.allow_other) return fail(`question ${q.id} does not allow another answer`)
        if (!r.selected.every((s) => q.options.some((o) => o.id === s))) return fail(`question ${q.id} selects an unknown option`)
        if (new Set(r.selected).size !== r.selected.length) return fail(`question ${q.id} selects an option twice`)
        const n = r.selected.length + (r.other === undefined ? 0 : 1)
        if (n === 0) return fail(`question ${q.id} has no answer`)
        if (!q.multi && n !== 1) return fail(`question ${q.id} takes exactly one answer`)
      }
      return ok
    },
    docs: "One to four multiple-choice questions (single or multi select, optional other)."
  },
  approve: {
    prompt: Schema.Struct({
      action: Schema.Struct({
        type: Schema.Literals(["command", "edit", "tool", "network", "install", "custom"]),
        summary: NonEmpty(500),
        command: Schema.optionalKey(Text(8000)),
        cwd: Schema.optionalKey(Text(1000)),
        tool: Schema.optionalKey(Text(200)),
        input: Schema.optionalKey(Schema.Unknown),
        diff: Schema.optionalKey(NonEmpty(64)),
        risk: Schema.optionalKey(OpClass)
      }),
      scopes: Schema.optionalKey(List(ApproveScope, 1, 3))
    }),
    answer: Schema.Struct({
      decision: Schema.Literals(["allow", "deny"]),
      scope: Schema.optionalKey(ApproveScope),
      reason: Schema.optionalKey(Text(2000)),
      updated_input: Schema.optionalKey(Schema.Unknown)
    }),
    priority: "high",
    needsMac: false,
    checkAnswer: (p: { scopes?: ReadonlyArray<string> }, a: { decision: string; scope?: string }) => {
      const scopes = p.scopes ?? ["once"]
      if (a.decision === "allow" && a.scope !== undefined && !scopes.includes(a.scope)) return fail(`scope ${a.scope} was not offered`)
      if (a.decision === "deny" && a.scope !== undefined) return fail("a denial has no scope")
      return ok
    },
    docs: "Permission for one action (command, edit, tool, network, install)."
  },
  confirm: {
    prompt: Schema.Struct({ statement: NonEmpty(2000), confirm_label: Schema.optionalKey(Text(40)), cancel_label: Schema.optionalKey(Text(40)), destructive: Schema.optionalKey(Schema.Boolean) }),
    answer: Schema.Struct({ confirmed: Schema.Boolean }),
    priority: "high",
    needsMac: false,
    docs: "A yes or no confirmation."
  },
  "sign-in": {
    prompt: Schema.Struct({ origin: NonEmpty(300), url: NonEmpty(2048), browser_tab: NonEmpty(128), profile: Schema.optionalKey(Text(128)), reason: Text(500) }),
    answer: browserStatus(["signed_in", "cancelled", "failed", "origin_changed"]),
    priority: "high",
    needsMac: true,
    docs: "The user signs in to a site in a user-owned copy of the agent's browser tab; the agent gets only a status."
  },
  passkey: {
    prompt: Schema.Struct({ origin: NonEmpty(300), rp_id: Schema.optionalKey(Text(300)), ceremony: Schema.Literals(["get", "create"]), browser_tab: NonEmpty(128), reason: Text(500) }),
    answer: browserStatus(["completed", "cancelled", "failed", "unavailable"]),
    priority: "high",
    needsMac: true,
    docs: "The user completes a passkey ceremony in a user-owned copy of the agent's browser tab; the agent gets only a status."
  },
  review: {
    prompt: Schema.Struct({ subject: Schema.Literals(["diff", "pr", "file", "document", "url", "plan"]), ref: NonEmpty(2048), checklist: Schema.optionalKey(List(NonEmpty(300), 0, 20)) }),
    answer: Schema.Struct({
      verdict: Schema.Literals(["approve", "request_changes", "comment"]),
      comment: Schema.optionalKey(Text(16_000)),
      notes: Schema.optionalKey(List(Schema.Struct({ path: NonEmpty(1000), line: Schema.optionalKey(Int(1, 10_000_000)), text: NonEmpty(4000) }), 0, 100))
    }),
    priority: "normal",
    needsMac: false,
    docs: "A review of a diff, PR, file, document, URL or plan."
  },
  input: {
    prompt: Schema.Struct({ schema: Schema.Unknown }),
    answer: Schema.Record(Schema.String, Schema.Unknown),
    priority: "high",
    needsMac: false,
    checkPrompt: (p: { schema: unknown }) => checkSubsetSchema(p.schema),
    checkAnswer: (p: { schema: unknown }, a: unknown) => checkSubsetValue(p.schema, a),
    docs: "A small form (flat object of string, number, integer, boolean and multi-select fields)."
  },
  file: {
    prompt: Schema.Struct({ purpose: NonEmpty(500), accept: List(NonEmpty(100), 0, 20), multiple: Schema.Boolean, max_bytes: Int(1, MAX_FILE_BYTES) }),
    answer: Schema.Struct({ files: List(FeedAttachment, 1, 20) }),
    priority: "high",
    needsMac: false,
    checkAnswer: (p: { multiple: boolean; max_bytes: number }, a: { files: ReadonlyArray<{ size: number }> }) => {
      if (!p.multiple && a.files.length !== 1) return fail("this request takes one file")
      if (a.files.some((f) => f.size > p.max_bytes)) return fail("a file is larger than the request allows")
      return ok
    },
    docs: "The user provides one or more files."
  },
  handoff: {
    prompt: Schema.Struct({ reason: NonEmpty(1000), resume_hint: Schema.optionalKey(Text(500)) }),
    answer: Schema.Struct({ status: Schema.Literals(["resumed", "taken_over", "declined"]), note: Schema.optionalKey(Text(2000)) }),
    priority: "high",
    needsMac: false,
    docs: "The agent hands its context (terminal, tab, session) to the user and waits."
  }
}

export const CUSTOM_KIND = /^x-[a-z0-9][a-z0-9-]{0,39}\.[a-z0-9][a-z0-9-]{0,39}$/
export const MAX_PROMPT_JSON = 16 * 1024
export const MAX_ANSWER_JSON = 64 * 1024

const decode = (schema: Schema.Top, value: unknown): { ok: true; value: unknown } | { ok: false; message: string } => {
  const exit = Schema.decodeUnknownExit(schema as Schema.Codec<unknown, unknown>)(value)
  return Exit.isSuccess(exit) ? { ok: true, value: exit.value } : { ok: false, message: String(exit.cause) }
}

const jsonSize = (v: unknown) => (v === undefined ? 0 : JSON.stringify(v).length)

/** Checks a request's prompt (and custom answer schema) at post time. */
export const checkPrompt = (kind: string, prompt: unknown, answerSchema: unknown): SubsetResult => {
  if (jsonSize(prompt) > MAX_PROMPT_JSON) return fail(`prompt is larger than ${MAX_PROMPT_JSON} bytes`)
  if (CUSTOM_KIND.test(kind)) {
    if (answerSchema === undefined) return fail("a custom kind needs answer_schema")
    return checkSubsetSchema(answerSchema)
  }
  const def = feedKinds[kind]
  if (!def) return fail(`unknown kind ${kind}`)
  if (answerSchema !== undefined) return fail("answer_schema is only for custom kinds")
  const d = decode(def.prompt, prompt ?? {})
  if (!d.ok) return fail(`invalid prompt for ${kind}: ${d.message}`)
  return def.checkPrompt ? def.checkPrompt(d.value) : ok
}

/** Checks an answer value against the item's kind, prompt and custom schema. */
export const checkAnswer = (kind: string, prompt: unknown, answerSchema: unknown, answer: unknown): SubsetResult => {
  if (jsonSize(answer) > MAX_ANSWER_JSON) return fail(`answer is larger than ${MAX_ANSWER_JSON} bytes`)
  if (CUSTOM_KIND.test(kind)) return checkSubsetValue(answerSchema, answer)
  const def = feedKinds[kind]
  if (!def) return fail(`unknown kind ${kind}`)
  const a = decode(def.answer, answer)
  if (!a.ok) return fail(`invalid answer for ${kind}: ${a.message}`)
  const p = decode(def.prompt, prompt ?? {})
  if (!p.ok) return fail("stored prompt no longer decodes")
  return def.checkAnswer ? def.checkAnswer(p.value, a.value) : ok
}

export const kindNeedsMac = (kind: string) => feedKinds[kind]?.needsMac ?? false
export const kindDefaultPriority = (kind: string): "low" | "normal" | "high" | "urgent" => feedKinds[kind]?.priority ?? "normal"
export const builtinKindNames = Object.keys(feedKinds)
