/**
 * Writes the conformance corpus from intent: every case states the outcome it
 * must have (a reject code, or a commit), the TypeScript core must agree, and
 * the full committed value is recorded so a second implementation (the Rust
 * crate `cmux-conversation`) can compare byte-for-byte JSON values.
 *
 *   node conformance/generate.ts           (from backend/packages/home-core)
 *
 * Review the diff of the JSON files after a reducer change: a changed commit
 * is a wire change for every owner.
 */
import { writeFileSync } from "node:fs"
import { create, type CreateRequest } from "../src/conversation/create.ts"
import type { OpRequest } from "../src/conversation/request.ts"
import type { ConversationHead, Op } from "../src/conversation/types.ts"
import { apply } from "../src/conversation/apply.ts"
import { CoreHost } from "../test/support/harness.ts"
import { cloudCases } from "./cloud-cases.ts"
import { localCases } from "./local-cases.ts"
import { searchCases } from "./search-cases.ts"

export type Expect = string | "commit"

export interface CaseInput {
  readonly name: string
  readonly expect: Expect
}

export interface OpCase {
  readonly name: string
  readonly head: ConversationHead
  readonly request: OpRequest
  readonly expect: { readonly commit: unknown } | { readonly reject: string }
}

export interface CreateCase {
  readonly name: string
  readonly create: CreateRequest
  readonly expect: { readonly head: unknown } | { readonly reject: string }
}

export type Case = OpCase | CreateCase

const plain = (value: unknown): unknown => JSON.parse(JSON.stringify(value))

/** Collects cases; each builder checks the intended outcome against the TypeScript core. */
export class Corpus {
  readonly cases: Array<Case> = []

  create(name: string, request: CreateRequest, expect: Expect): void {
    const result = create(request)
    const outcome = result.ok ? "commit" : result.code
    if (outcome !== expect) throw new Error(`${name}: expected ${expect}, got ${outcome}`)
    this.cases.push({ name, create: plain(request) as CreateRequest, expect: result.ok ? { head: plain(result.head) } : { reject: result.code } })
  }

  /** Records `op` against the host's current head, then commits it to the host when it succeeds. */
  op(host: CoreHost, name: string, actor: string, key: string, op: Op, expect: Expect, extra: Partial<OpRequest> = {}): void {
    const request = host.request(actor, key, op, extra)
    const result = apply(host.head, request)
    const outcome = result.ok ? "commit" : result.code
    if (outcome !== expect) throw new Error(`${name}: expected ${expect}, got ${outcome}`)
    this.cases.push({
      name,
      head: plain(host.head) as ConversationHead,
      request: plain(request) as OpRequest,
      expect: result.ok ? { commit: plain(result.commit) } : { reject: result.code }
    })
    if (result.ok) host.commit(op, result.commit)
  }
}

const NOTES = [
  "Each case is {name, head, request, expect} or {name, create, expect}. expect is {commit}, {head} (create) or {reject: code}.",
  "request = the Rust OpRequest fields (actor, idempotency_key, op tagged by kind, now, new_message_id, target, reply_target, last_message) plus actor_addresses (cloud only).",
  "A runner calls apply(head, request). REQUIRED for the Rust owner: every head carries agent_text_streak (0 at create) and last_agent_text_at; a text send by an agent adds 1 and sets last_agent_text_at, a human text resets the streak to 0, a text-less work card changes neither; an agent text is refused with agent_budget at streak >= 4 and agent_rate within 2000 ms of last_agent_text_at, after every other rule passes.",
  "Compare JSON values: optional fields are omitted when absent; object key order does not matter.",
  "Commit = {head, message?, change}; change kinds: message, message-updated, read-cursor, conversation, invite.",
  "The head guard counts a retracted agent message and applies the gap to the last agent text message however old. The cases named 'loop guard:' are the work-card bypass that a row window misses.",
  "Cloud participants.add of an agent: only its owner (a stored record's owner_user wins over the op's), unless request.trusted_participant is true (the host's reach policy approved it and stamped owner_user and display_name).",
  "Cloud invite.accept: request.actor_addresses holds the address ids of the actor's verified emails; the host passes it only when the email is verified. Group invites bind at once only for email with a matching address; otherwise status pending_approval.",
  "The host derives token_hash: invite.create stores hash(hash(secret)), and the Domain hashes the accept proof hash(secret), so no event carries a value that can accept."
]

const write = (file: string, cases: ReadonlyArray<Case>) => {
  const body = { format: "cmux-conversation-conformance/1", notes: NOTES, cases }
  writeFileSync(new URL(file, import.meta.url), `${JSON.stringify(body, null, 1)}\n`)
  console.log(`${file}: ${cases.length} cases`)
}

const local = new Corpus()
localCases(local)
write("conversation-cases.json", local.cases)
const cloud = new Corpus()
cloudCases(cloud)
write("conversation-cloud-cases.json", cloud.cases)

const search = searchCases()
writeFileSync(
  new URL("conversation-search-cases.json", import.meta.url),
  `${JSON.stringify({ format: "cmux-conversation-search/1", notes: ["Each case: {name, actor, input {query, limit 1-100}, sources [{head, messages}], expect {hits} | {reject}}. Run searchConversations(actor, input, sources) and compare JSON values exactly (order and snippets included)."], cases: search }, null, 1)}\n`
)
console.log(`conversation-search-cases.json: ${search.length} cases`)
