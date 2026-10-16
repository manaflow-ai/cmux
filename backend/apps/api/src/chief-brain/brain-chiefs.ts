import { Type } from "@earendil-works/pi-ai"
import type { ToolRegistration } from "@earendil-works/pi-durable"
import type { OwnerFrame } from "@cmux/ownership"
import type { Env } from "../env.ts"
import { signInRules } from "../policy-gate.ts"
import { type BrainConfig, patchError } from "./brain-store.ts"

/**
 * The `chiefs` tool of a Cloud Chief (Lawrence 2026-10-14: Chiefs make and edit other Chiefs; the
 * local daemon's rules, server/chief_manage.rs). Server code only: the calling Chief is the brain's
 * own configured agent, never a request field.
 *
 * - The grant is the `chiefs` setting of the Chief's settings object (missing = on).
 * - create: a chief record in the owner's UserDO (`chiefManage`, a create with only display_name),
 *   then the new Chief's brain on with the caller's models and the given profile.
 * - update: another Chief's display_name (UserDO), role, personality, instructions (its settings); a
 *   Chief the person made (no created_by): display_name and role only.
 * - Ceiling: a new or edited Chief runs the caller's model and compactor model; an edit needs the
 *   target's grant within the caller's (it runs the caller's model, or has no brain on yet); the
 *   default chief's grant (models, chiefs) is the person's; no archive by a Chief.
 */
const Args = Type.Object({
  action: Type.Union([Type.Literal("list"), Type.Literal("get"), Type.Literal("create"), Type.Literal("update")]),
  chief: Type.Optional(Type.String({ description: "The Chief's id (agent_...) or its name; for get and update." })),
  // Lengths are checked where they are stored (chief.create/update, configure's patchError), not in the schema the model reads.
  display_name: Type.Optional(Type.String()),
  role: Type.Optional(Type.String()),
  personality: Type.Optional(Type.String()),
  instructions: Type.Optional(Type.String()),
  model: Type.Optional(Type.String())
})
type ArgsT = { action: "list" | "get" | "create" | "update"; chief?: string; display_name?: string; role?: string; personality?: string; instructions?: string; model?: string }

export const CHIEFS_DESCRIPTION =
  "See, make and edit the person's other Chiefs. action list returns every Chief; get returns one (chief: its id or name). create makes a new Chief (display_name required; role, personality, instructions) that runs on your own model; the answer says whether its brain is on, and you tell the person exactly that (never that it answers when it is not on). update changes another Chief (chief plus display_name, role, personality or instructions). You cannot give a Chief more than you hold, edit a Chief that holds more than you, change the default Chief's grant, or delete a Chief (the person does)."

interface Record0 { id: string; display_name: string; is_default: boolean; rev: number; archived_at: string | null; created_by?: string }
type Settings = { status(): Promise<{ config: BrainConfig }>; configure(agent: string, owner: string, patch: Record<string, unknown>): Promise<{ ok: true; config: BrainConfig } | { ok: false; code: string; message: string }> }
type UserStub = {
  readOp(entity: string, p: unknown, op: string, params: unknown): Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
  homeTeamsOf(entity: string): Promise<Array<{ team: string }>>
  chiefManage(entity: string, agent: string, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "script" }): Promise<{ frames: ReadonlyArray<OwnerFrame> }>
}

export class ChiefsRefused extends Error {
  constructor(readonly reason: string, message: string) {
    super(`Not allowed (${reason}): ${message}.`)
  }
}

const settings = (env: Env, agent: string) => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(agent)) as unknown as Settings
const user = (env: Env, owner: string) => env.USER_DO.get(env.USER_DO.idFromName(owner)) as unknown as UserStub

const listChiefs = async (env: Env, owner: string): Promise<Array<Record0>> => {
  const r = await user(env, owner).readOp(owner, { identity: `session:${owner}`, kind: "session", user: owner }, "chief.list", {})
  if (!r.ok) throw new Error(`chief.list: ${r.code}`)
  return ((r.value as { chiefs?: Array<Record0> }).chiefs ?? []).filter((c) => c.archived_at === null)
}

const resolve = (all: ReadonlyArray<Record0>, wanted: string | undefined): Record0 => {
  const w = wanted?.trim()
  if (!w) throw new Error("chiefs: give chief, its id (agent_...) or its name")
  const byId = all.find((c) => c.id === w)
  if (byId) return byId
  const named = all.filter((c) => c.display_name === w)
  if (named.length === 1) return named[0]!
  throw new Error(named.length === 0 ? `chiefs: no Chief is named ${w}` : `chiefs: more than one Chief is named ${w}; use its id`)
}

const committed = (frames: ReadonlyArray<OwnerFrame>): Record0 => {
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (!f) throw new Error("chiefs: no answer from the owner")
  if (f.t === "reject") throw new ChiefsRefused(f.code, f.message)
  return (f as { value: Record0 }).value
}

const configured = async (env: Env, agent: string, owner: string, patch: Record<string, unknown>) => {
  const r = await settings(env, agent).configure(agent, owner, patch)
  if (!r.ok) throw new ChiefsRefused(r.code, r.message)
  return r.config
}

/** One `chiefs` call of the Chief `agent` of `owner`; the answer text for the model. */
export const manageChiefs = async (env: Env, agent: string, owner: string, args: ArgsT, key: string): Promise<string> => {
  const me = (await settings(env, agent).status()).config
  if (!me.chiefs) throw new ChiefsRefused("chief_manage_denied", "this Chief has no chiefs tool; the person grants it")
  const all = await listChiefs(env, owner)
  if (args.action === "list") return JSON.stringify(all.map((c) => ({ id: c.id, display_name: c.display_name, is_default: c.is_default })), null, 2)
  if (args.action === "get") {
    const c = resolve(all, args.chief)
    const t = (await settings(env, c.id).status()).config
    return JSON.stringify({ ...c, role: t.role, personality: t.personality, instructions: t.instructions, model: t.model, enabled: t.enabled, chiefs: t.chiefs }, null, 2)
  }
  if (args.model !== undefined && args.model !== me.model) throw new ChiefsRefused("grant_exceeds_caller", "a Chief gives another Chief only the model it runs itself [model]")
  const profile = { role: args.role, personality: args.personality, instructions: args.instructions }
  // The limits are checked before any write, so a refused profile never leaves a half-made or half-renamed Chief.
  const invalid = patchError(profile, () => true) ?? (args.display_name !== undefined && (args.display_name.trim().length === 0 || [...args.display_name].length > 100) ? "display_name must be 1 to 100 characters" : null)
  if (invalid) throw new ChiefsRefused("validation.invalid", invalid)
  if (args.action === "create") {
    if (!args.display_name) throw new Error("chiefs: create needs display_name")
    // agents.allowedClasses (P17-4): the /v1/ops create checks the session's team; a Chief has none, so every team of the owner must allow chiefs.
    for (const { team } of await user(env, owner).homeTeamsOf(owner)) {
      if (!(await signInRules(env, team, owner)).allowed_classes.includes("mux")) throw new ChiefsRefused("policy.denied", "a team of this person does not allow chiefs (agents.allowedClasses)")
    }
    const frame = { t: "op" as const, op: "chief.create", params: { display_name: args.display_name }, idempotency_key: `chiefs:${agent}:${key}`, origin: "script" as const }
    const made = committed((await user(env, owner).chiefManage(owner, agent, frame)).frames)
    const cfg = await configured(env, made.id, owner, { enabled: true, model: me.model, compactor_model: me.compactor_model, chiefs: true, ...profile })
    // The truth about its brain: on only when its settings say enabled and this deployment forwards wakes to brains.
    const brain = cfg.enabled && env.CHIEF_BRAIN_ENABLED === "1" ? { state: "started" } : { state: "not_started", reason: cfg.enabled ? "brains_off" : "not_enabled" }
    const note = brain.state === "started"
      ? "Its brain is on: it answers in its own conversation. Tell the person so."
      : "Its brain is NOT on here, so it will not answer. Tell the person plainly that the new Chief exists but does not answer yet."
    return `${JSON.stringify({ ...made, ...profile, brain }, null, 2)}\n${note}`
  }
  const target = resolve(all, args.chief)
  if (target.id === agent) throw new ChiefsRefused("chief_self_edit_denied", "change yourself through the person")
  const t = (await settings(env, target.id).status()).config
  if (target.is_default && args.model !== undefined) throw new ChiefsRefused("chief_default_grant", "the default Chief's grant is the person's [model]")
  // A Chief the person made (no created_by): name and role only, never its instructions, personality or model.
  const personOnly = ["personality", "instructions", "model"].filter((k) => args[k as keyof ArgsT] !== undefined)
  if (target.created_by === undefined && personOnly.length > 0) throw new ChiefsRefused("chief_person_made_fields", `a Chief changes only the name and role of a Chief the person made [${personOnly.join(", ")}]`)
  if (t.model !== me.model || t.compactor_model !== me.compactor_model || (t.chiefs && !me.chiefs)) throw new ChiefsRefused("target_exceeds_caller", "that Chief runs another model; only the person changes it [model]")
  let record = target
  if (args.display_name !== undefined && args.display_name !== target.display_name) {
    const frame = { t: "op" as const, op: "chief.update", params: { chief: target.id, expected_rev: target.rev, display_name: args.display_name }, idempotency_key: `chiefs:${agent}:${key}:name`, origin: "script" as const }
    record = committed((await user(env, owner).chiefManage(owner, agent, frame)).frames)
  }
  const patch = Object.fromEntries(Object.entries({ ...profile, model: args.model }).filter(([, v]) => v !== undefined))
  const cfg = Object.keys(patch).length > 0 ? await configured(env, target.id, owner, patch) : t
  return `${JSON.stringify({ ...record, role: cfg.role, personality: cfg.personality, instructions: cfg.instructions }, null, 2)}\nChanged text reaches that Chief's prompt on its next turn.`
}

/** The tool, for a brain whose `who()` names its chief and owner (null: not bound yet). */
export const chiefsTools = (env: Env, who: () => { agent: string | null; owner: string | null }): [ToolRegistration<typeof Args>] => [
  {
    name: "chiefs",
    description: CHIEFS_DESCRIPTION,
    parameters: Args,
    replay: "unsafe",
    execute: async (args, api) => {
      const { agent, owner } = who()
      // The call id keys the writes: a retried call commits once.
      const text = !agent || !owner
        ? "chiefs: this brain has no chief yet"
        : await manageChiefs(env, agent, owner, args as ArgsT, api.callId).catch((e: unknown) => (e instanceof Error ? e.message : String(e)))
      return { content: [{ type: "text", text }] }
    }
  }
]
