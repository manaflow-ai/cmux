import type { Env } from "../env.ts"
import { Effort, ModelName } from "./contract.ts"
import { Schema } from "effect"

/**
 * Where each Chief model runs, all from configuration so an enterprise can point the brain at its own
 * routes (nothing here is a fixed host or key):
 *
 * - Claude (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`): an Anthropic-Messages route
 *   in front of Bedrock. CHIEF_BRAIN_CLAUDE_URL (default: the Chatmux metered route),
 *   CHIEF_BRAIN_CLAUDE_AUTH `stack` (default: X-Stack-Auth of a signed-in person, claude-auth.ts) or
 *   `bearer` (secret CHIEF_BRAIN_CLAUDE_TOKEN as `Authorization: Bearer`), CHIEF_BRAIN_CLAUDE_MODELS
 *   (the Claude names the route serves, comma separated; default `claude-opus-5-5`, the only model
 *   the Chatmux route serves today). A route that serves more than one model gets the name in the
 *   request body's `model`.
 * - `openrouter:<vendor>/<model>`: OpenRouter with the Worker secret OPENROUTER_API_KEY;
 *   OPENROUTER_BASE_URL overrides the endpoint.
 * - `fake` and Workers AI `@cf/...` as before (models.ts).
 *
 * Until prepaid credits land (UsageMeterDO), Claude and OpenRouter bill a deployment account, so
 * only owners on CHIEF_BRAIN_CLAUDE_OWNERS(+_EXTRA) may pick them.
 */
export const OPUS = "claude-opus-5-5"
export const SONNET = "claude-sonnet-5-5"
export const HAIKU = "claude-haiku-5-5"
export const CLAUDE_NAMES = [OPUS, SONNET, HAIKU] as const
const DEFAULT_CLAUDE_URL = "https://chatmux.dev/api/claude-david"
export const OPENROUTER_PREFIX = "openrouter:"
const DEFAULT_OPENROUTER_URL = "https://openrouter.ai/api/v1"

export const isClaude = (name: string | undefined | null): name is string => typeof name === "string" && (CLAUDE_NAMES as ReadonlyArray<string>).includes(name)
export const isOpenRouter = (name: string | undefined | null): name is string => typeof name === "string" && name.startsWith(OPENROUTER_PREFIX)
/** A model billed to a deployment account (Claude route or OpenRouter): allow-list, holder cap, never the compactor. */
export const isMetered = (name: string | undefined | null): name is string => isClaude(name) || isOpenRouter(name)

export interface ClaudeRoute {
  readonly url: string
  readonly auth: "stack" | "bearer"
  readonly models: ReadonlyArray<string>
  /**
   * Send effort (`output_config`) and `thinking.display` in the Bedrock body. Off by default on the
   * `stack` route: the Chatmux route drops `output_config` and the extended body is not yet proven
   * there; on by default for a `bearer` route; CHIEF_BRAIN_CLAUDE_EFFORT_BODY "1"/"0" overrides.
   */
  readonly effortBody: boolean
}
export const claudeRoute = (env: Env): ClaudeRoute => ({
  url: env.CHIEF_BRAIN_CLAUDE_URL || DEFAULT_CLAUDE_URL,
  auth: env.CHIEF_BRAIN_CLAUDE_AUTH === "bearer" ? "bearer" : "stack",
  models: (env.CHIEF_BRAIN_CLAUDE_MODELS || OPUS).split(",").map((s) => s.trim()).filter(isClaude),
  effortBody: env.CHIEF_BRAIN_CLAUDE_EFFORT_BODY ? env.CHIEF_BRAIN_CLAUDE_EFFORT_BODY === "1" : env.CHIEF_BRAIN_CLAUDE_AUTH === "bearer"
})
export const openRouterUrl = (env: Env): string => env.OPENROUTER_BASE_URL || DEFAULT_OPENROUTER_URL

/** Whether the route has its credential configured (the stack secret, or the bearer token). */
export const claudeRouteReady = (env: Env): boolean => {
  if (claudeRoute(env).auth === "bearer") return !!env.CHIEF_BRAIN_CLAUDE_TOKEN
  try {
    const v = JSON.parse(env.CHIEF_BRAIN_CLAUDE_STACK_AUTH ?? "") as { refreshToken?: unknown }
    return typeof v.refreshToken === "string" && v.refreshToken.length > 0
  } catch {
    return false
  }
}

/** Whether this deployment can run `name` at all. */
export const offers = (env: Env, name: string): boolean => {
  if (isClaude(name)) return claudeRouteReady(env) && claudeRoute(env).models.includes(name)
  if (isOpenRouter(name)) return !!env.OPENROUTER_API_KEY
  return Schema.is(ModelName)(name)
}

/** Owners whose Chiefs may run on a metered model (Claude route or OpenRouter). */
export const meteredOwner = (env: Env, owner: string | null): boolean =>
  owner !== null && owner !== "" && `${env.CHIEF_BRAIN_CLAUDE_OWNERS ?? ""},${env.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""}`.split(",").map((s) => s.trim()).filter(Boolean).includes(owner)

export const validModelName = (v: unknown): v is string => Schema.is(ModelName)(v)
export const validEffort = (v: unknown): boolean => Schema.is(Effort)(v)

export type Refusal = { readonly ok: false; readonly code: string; readonly message: string }

/** Why an owner's patch may not use its models here, or null (names are already valid). */
export const modelRefusal = (env: Env, owner: string, patch: { readonly model?: unknown; readonly compactor_model?: unknown }): Refusal | null => {
  // The compactor runs in the background with no per-call cap: never on a metered model until the
  // model gateway with prepaid credits meters it (then Haiku is its default where the route serves it).
  const c = patch.compactor_model
  if (typeof c === "string" && isMetered(c)) return { ok: false, code: "validation.invalid", message: `the compactor cannot run on ${c} here` }
  const m = patch.model
  if (typeof m !== "string" || (!isClaude(m) && !isOpenRouter(m))) return null
  if (!offers(env, m) || !meteredOwner(env, owner))
    return { ok: false, code: isClaude(m) ? "chief_claude_unavailable" : "chief_model_unavailable", message: `${m} is not available for this account here` }
  return null
}

/** The compactor's default: CHIEF_BRAIN_COMPACTOR_MODEL (never metered), else the turn model when it is not metered, else the fallback. */
export const compactorDefault = (env: Env, turnModel: string, fallback: string): string => compactorModel(env, env.CHIEF_BRAIN_COMPACTOR_MODEL || turnModel, fallback) || "fake"

/** The compactor's model at run time: a metered model becomes the fallback (see modelRefusal). */
export const compactorModel = (_env: Env, set: string, fallback: string): string => (isMetered(set) ? (isMetered(fallback) ? "fake" : fallback) : set)
