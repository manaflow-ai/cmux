import type { Env } from "../env.ts"
import type { OwnerFrame, Principal } from "@cmux/ownership"
import { authorizeDefaultMachine, defaultHandId, ensureDefaultHand, type DefaultChiefMachine, type DefaultHandScope } from "../chief-default-hand.ts"
import { asDaemonUser, layoutSelector } from "../cloud-acpmux-guest.ts"
import { handStub } from "../hand-api.ts"
import type { HandReply, HandSummary, StoredEvent } from "../hand-wire.ts"
import type { ChiefBrainDO } from "./brain-do.ts"
import { chiefRecord, chiefPrincipal, postText, typing } from "./brain-io.ts"
import { writeConfig } from "./brain-store.ts"
import { clip, upsertStep } from "./brain-runs.ts"
import { OWNER_APPROVAL_REQUIRED } from "./effect-policy.ts"
import type { ChiefProfile } from "./prompts.ts"
import { startMachineAgent, machineAgentEvents, stopMachineAgent } from "./brain-machine-acp.ts"

export type MachineHarness = "claude" | "codex"
export interface MachineRoute { binding: DefaultChiefMachine; harness: MachineHarness }
export type MachineState = {
  phase: "dispatching" | "running" | "waiting_auth" | "done" | "failed"
  operation: string
  hand: string
  cwd: string
  session?: string
  after: number
  text: string
  reason?: string
  /** A fresh attempt is allowed only after confirmed auth refusal before any output/tools. */
  authRetrySafe?: boolean
  attempt?: number
}
export type MachineOutcome = { ok: true; text: string } | { ok: false; reason: string } | { pending: "auth" | "provisioning" }
export type LoginStart = { loginId: string; url: string; userCode?: string; needsCode: boolean; expiresAtMs?: number }
const SIGN_IN_HOSTS = new Set(["claude.com", "claude.ai", "platform.claude.com", "console.anthropic.com", "auth.anthropic.com", "auth.openai.com"])
const MACHINE_STATE = (id: string) => `machine:${id}`
const TRANSIENT = new Set(["chief.machine.transport_unavailable", "chief.machine.owner_unavailable", "chief.machine.hand_offline", "chief.machine.carrier_unavailable", "chief.machine.start_unavailable", "chief.machine.not_running", "chief.hand.offline", "owner.unreachable", "provisioning_pending"])
export const machineRetryable = (error: unknown): boolean => !(error instanceof Error) || TRANSIENT.has(error.message) || !/^(chief\.machine\.|hand\.|revoked$|disabled$|other_chief$|chief_archived$|chief_placed$)/.test(error.message)
export const authorizeMachineHand = async (env: Env, scope: DefaultHandScope, cwd?: string): Promise<void> => {
  const hand = handStub(env, defaultHandId(scope)) as unknown as { info(c: { kind: "chief"; user: string; agent: string }): Promise<HandReply<HandSummary & { hello: { profile?: string; roots?: Array<string> } | null }>> }
  const info = await hand.info({ kind: "chief", user: scope.owner, agent: scope.chief })
  if (!info.ok) throw new Error(info.error.code)
  // info() also returns a revoked hand for owner UI display. Its success is not authorization.
  if (info.value.revoked_at !== null || info.value.paired_at === null) throw new Error("hand.revoked")
  if (info.value.level !== "full") throw new Error("chief.machine.permission_required")
  if (!info.value.online) throw new Error("chief.machine.hand_offline")
  if (info.value.profile !== "sandbox" || info.value.hello?.profile !== "sandbox") throw new Error("chief.machine.permission_required")
  if (cwd && !info.value.hello.roots?.includes(cwd)) throw new Error("chief.machine.cwd_changed")
}
export const machineSignInURL = (raw: unknown, harness: MachineHarness): string | null => {
  if (typeof raw !== "string" || raw.length > 4096 || /[^\x21-\x7e]/.test(raw)) return null
  try {
    const url = new URL(raw)
    if (url.protocol !== "https:" || url.username || url.password || url.port || !SIGN_IN_HOSTS.has(url.hostname.toLowerCase())) return null
    const path = url.pathname.replace(/\/$/, "")
    if (harness === "codex") {
      if (url.hostname !== "auth.openai.com" || !["/codex/device", "/deviceauth", "/device"].includes(path)) return null
    } else if (url.hostname === "auth.openai.com" || !(path === "/oauth/authorize" || (url.hostname === "claude.com" && path === "/cai/oauth/authorize"))) return null
    return url.toString()
  } catch { return null }
}

export const machineHarness = (harness: string | null): MachineHarness | null => harness === null || harness === "claude" ? "claude" : harness === "codex" ? "codex" : null
/** Machine agents have the harness's real tools, rather than the hosted brain's Pi tools. */
export const machinePrompt = (profile: ChiefProfile, binding: DefaultChiefMachine, cwd: string, blocks: Array<string>): string => [
  `You are the Chief, working for your owner on their persistent cmux Cloud machine. Carry out the newest request directly using your harness's available filesystem, terminal and other tools. Earlier messages below are context. Return the result as a message to the person, without adding a conversation header. Do not ask them to create, pair, enable or connect a machine: this machine is already provisioned. Provider sign-in is handled by the product when required.

Work in the current project directory. For a request to build a web page or app, create it, start its server listening on 0.0.0.0, and verify the response. Discover this machine's preview and sharing support from its installed tools' help, environment and existing /etc/cmux metadata. Use only a URL returned by that support; never guess a hostname from an ID or present a localhost URL as a remotely accessible link. Fetch the returned URL and read the response before reporting that it works. Return a Markdown link to the running page. Do not change authentication or sharing permissions unless the owner's request authorizes it.

Use only tools actually available in this harness. The hosted brain's zoom, spawn and hub APIs are not provided by this adapter. Report any concrete failure accurately instead of claiming the build or URL works.`,
  `Machine context: ${JSON.stringify({ workspace: binding.workspace, machine: binding.machine, provider: binding.provider, cwd })}`,
  `Chief identity: ${JSON.stringify({ name: profile.display_name, role: profile.role, personality: profile.personality })}`,
  ...(profile.instructions.trim() ? [`Additional instructions from the Chief's configuration:\n${profile.instructions}`] : []),
  `Conversation input:\n${blocks.join("\n\n")}`,
].join("\n\n")
export const readMachineRoute = (sql: SqlStorage): MachineRoute | null => {
  const value = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'machine_route'`).toArray()[0]?.value
  if (!value) return null
  try { return JSON.parse(value) as MachineRoute } catch { return null }
}
export const readMachineState = (sql: SqlStorage, id: string): MachineState | null => {
  const value = sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, MACHINE_STATE(id)).toArray()[0]?.value
  return value ? JSON.parse(value) as MachineState : null
}
const save = (b: ChiefBrainDO, id: string, state: MachineState) => writeConfig(b.sql, { [MACHINE_STATE(id)]: JSON.stringify(state) })

/** Wake only the server-proven default carrier, through the normal cap/budget-checked owner op. */
export const wakeDefaultMachine = async (b: ChiefBrainDO, scope: DefaultHandScope): Promise<boolean> => {
  const cloud = await authorizeDefaultMachine(b.doEnv, scope, { running: false })
  const principal: Principal = { identity: `session:${scope.owner}`, kind: "session", user: scope.owner, team: scope.team }
  const read = await cloud.readOp(scope.team, principal, "cloud.machine.get", { machine: scope.connection_machine })
  if (!read.ok) throw new Error("chief.machine.carrier_unavailable")
  const machine = read.value as { status: string }
  if (machine.status === "running") return true
  if (machine.status === "starting" || machine.status === "pausing" || machine.status === "provisioning") return false
  if (machine.status !== "paused") throw new Error("chief.machine.carrier_unavailable")
  if (typeof read.revision !== "string" || !read.revision) throw new Error("chief.machine.carrier_unavailable")
  const starter = cloud as typeof cloud & { submit(entity: string, principal: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "script" }): Promise<{ frames: ReadonlyArray<OwnerFrame> }> }
  const reply = await starter.submit(scope.team, principal, { t: "op", op: "cloud.machine.start", params: { machine: scope.connection_machine }, idempotency_key: `chief-machine-wake:${scope.chief}:${scope.install}:${read.revision}`, origin: "script" })
  const result = reply.frames.find((f) => f.t === "result" || f.t === "reject")
  if (!result || result.t === "reject") throw new Error(result?.code ?? "chief.machine.start_unavailable")
  return false
}

/** One fixed local acpmux request. Caller data is stdin; no shell text or credential is recorded. */
const rpc = async (env: Env, scope: DefaultHandScope, method: string, params: unknown, timeout: number, feature?: string): Promise<unknown> => {
  const cloud = await authorizeDefaultMachine(env, scope)
  await authorizeMachineHand(env, scope)
  const frames = [
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: 1 } },
    { jsonrpc: "2.0", id: 2, method, params },
  ].map((f) => JSON.stringify(f)).join("\n") + "\n"
  // Use the hand's isolated daemon, so the auth probe and login use the same harness/account
  // configuration as agent.start. The fixed default-machine scope was validated above.
  const command = `${layoutSelector()} && ${asDaemonUser(`env -u ACPMUX_SOCKET ACPMUX_HOME="$CMUX_TUI_HOME/.cmux-chief-hand/acpmux" CMUX_CLAUDE_AUTH=own CMUX_CODEX_AUTH=own "$CMUX_TUI_BIN" acp stdio`, { exec: true })}`
  const reply = await cloud.automationExec(scope.team, scope.owner, scope.connection_machine, command, new TextEncoder().encode(frames), timeout)
  if (!reply.ok || reply.exitCode !== 0) throw new Error("chief.machine.transport_unavailable")
  // This is a protocol safety bound for tiny login/auth envelopes, never agent build output.
  if ((method.startsWith("_acpmux/agent_login/") || method === "_acpmux/session/auth") && reply.stdout.length > 256_000) throw new Error("chief.machine.transport_invalid")
  const rows = reply.stdout.split("\n").flatMap((line) => { try { return [JSON.parse(line) as { id?: number; result?: unknown; error?: { code?: number; data?: { reason?: unknown } } }] } catch { return [] } })
  const initialized = rows.find((f) => f.id === 1)?.result as { _meta?: { acpmux?: { features?: Array<string> } } } | undefined
  if (feature && !initialized?._meta?.acpmux?.features?.includes(feature)) throw new Error(`chief.machine.${feature}_unsupported`)
  const result = rows.find((f) => f.id === 2)
  if (result?.error) {
    const reason = result.error.data?.reason
    throw Object.assign(new Error("chief.machine.request_refused"), { code: result.error.code, data: { reason: typeof reason === "string" && /^[a-z0-9_.-]+$/.test(reason) ? reason : undefined } })
  }
  if (!result || result.result === undefined) throw new Error("chief.machine.request_refused")
  return result.result
}

/** Only affirmative machine evidence starts OAuth. Unknown never becomes a sign-in requirement. */
export const machineAuthState = (value: { state?: string; source?: string } | null): "ready" | "signed_out" | "unknown" => {
  if (!value) return "unknown"
  if ((value.state === "signedOut" || value.state === "expired") && value.source && value.source !== "none") return "signed_out"
  return value.state === "ready" ? "ready" : "unknown"
}
export const machineAuth = async (env: Env, scope: DefaultHandScope, harness: MachineHarness, cwd: string): Promise<"ready" | "signed_out" | "unknown"> => {
  // An older daemon may not answer the probe. Its lack of evidence is never a login refusal.
  const value = await rpc(env, scope, "_acpmux/session/auth", { target: { harness, cwd }, refresh: true }, 30_000, "sessionAuth").catch(() => null) as { state?: string; source?: string } | null
  return machineAuthState(value)
}

export const machineLoginStart = async (env: Env, scope: DefaultHandScope, harness: MachineHarness): Promise<LoginStart> => {
  const value = await rpc(env, scope, "_acpmux/agent_login/start", { agent: harness }, 30_000, "agent_login") as LoginStart
  const url = machineSignInURL(value.url, harness)
  if (typeof value.loginId !== "string" || !value.loginId || !url) throw new Error("chief.machine.invalid_login")
  if (value.expiresAtMs !== undefined && (!Number.isFinite(value.expiresAtMs) || value.expiresAtMs <= Date.now())) throw new Error("chief.machine.login_expired")
  return { loginId: value.loginId, url, needsCode: value.needsCode === true, ...(typeof value.userCode === "string" ? { userCode: value.userCode } : {}), ...(typeof value.expiresAtMs === "number" ? { expiresAtMs: value.expiresAtMs } : {}) }
}
export const machineLoginFinish = async (env: Env, scope: DefaultHandScope, loginId: string, code?: string): Promise<boolean> => {
  // Stay within every carrier's five-minute exec limit. The daemon owns the longer device
  // flow; a later explicit finish checks fresh auth before retrying, without replaying a code.
  const value = await rpc(env, scope, "_acpmux/agent_login/finish", { loginId, ...(code ? { code } : {}) }, 240_000, "agent_login") as { signedIn?: boolean }
  return value.signedIn === true
}
export const machineLoginCancel = async (env: Env, scope: DefaultHandScope, loginId: string): Promise<void> => {
  await rpc(env, scope, "_acpmux/agent_login/cancel", { loginId }, 15_000, "agent_login")
}

/** Owner-session routes call this on the conversation brain; codes are used once and never stored. */
export const machineLogin = async (b: ChiefBrainDO, owner: string, run: string, action: "status" | "start" | "finish" | "cancel", value: { loginId?: string; code?: string } = {}): Promise<unknown> => {
  const cfg = b.config(), route = b.machineRoute(), state = readMachineState(b.sql, run)
  const resumedKey = `machine-login-resumed:${run}`
  if (cfg.owner !== owner || !cfg.agent || !route) throw new Error("chief.machine.login_not_pending")
  if (state?.phase !== "waiting_auth" && (action === "status" || action === "finish") && b.sql.exec(`SELECT 1 FROM cb_config WHERE name = ?`, resumedKey).toArray().length) return { signedIn: true, resumed: true }
  if (state?.phase !== "waiting_auth") throw new Error("chief.machine.login_not_pending")
  const turn = b.sql.exec<{ status: string; effect_authorized: number }>(`SELECT status, effect_authorized FROM cb_turn WHERE id = ?`, run).toArray()[0]
  if (turn?.status !== "running" || turn.effect_authorized !== 1) throw new Error("chief.machine.login_not_pending")
  const admission = await b.admitted(cfg.agent, owner, false)
  if (!admission.ok || !admission.machine) throw new Error("chief.machine.login_refused")
  const scope = { ...admission.machine.binding, owner, chief: cfg.agent }
  if (state.hand !== defaultHandId(scope)) throw new Error("chief.machine.binding_changed")
  await authorizeMachineHand(b.doEnv, scope, state.cwd)
  const loginKey = `machine-login:${run}`
  const stored = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, loginKey).toArray()[0]?.value
  const current = stored ? JSON.parse(stored) as LoginStart : null
  if (action === "status") return { waiting: true, harness: admission.machine.harness, login: current }
  if (action === "start") {
    if (current && (current.expiresAtMs === undefined || current.expiresAtMs > Date.now())) return current
    const key = `machine-login-starting:${run}`
    const starting = Number(b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, key).toArray()[0]?.value ?? "0")
    if (starting + 35_000 > Date.now()) throw new Error("chief.machine.login_busy")
    const stamp = String(Date.now())
    writeConfig(b.sql, { [key]: stamp })
    try {
      const started = await machineLoginStart(b.doEnv, scope, admission.machine.harness)
      writeConfig(b.sql, { [loginKey]: JSON.stringify(started) })
      return started
    } finally { b.sql.exec(`DELETE FROM cb_config WHERE name = ? AND value = ?`, key, stamp) }
  }
  if (!current || value.loginId !== current.loginId) throw new Error("chief.machine.login_changed")
  if (action === "cancel") {
    await machineLoginCancel(b.doEnv, scope, current.loginId)
    b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, loginKey)
    return { cancelled: true }
  }
  const resume = async () => {
    // The owner may disable/revoke or change the binding while the provider request is live.
    await authorizeDefaultMachine(b.doEnv, scope)
    await authorizeMachineHand(b.doEnv, scope, state.cwd)
    const latest = await b.admitted(cfg.agent!, owner, false)
    if (!latest.ok || !latest.machine || defaultHandId({ ...latest.machine.binding, owner, chief: cfg.agent! }) !== state.hand) throw new Error("chief.machine.login_refused")
    const kicked = b.doCtx.storage.transactionSync(() => {
      if (b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, resumedKey).toArray()[0]?.value === current.loginId) return false
      const still = readMachineState(b.sql, run)
      const active = b.sql.exec<{ status: string; effect_authorized: number }>(`SELECT status, effect_authorized FROM cb_turn WHERE id = ?`, run).toArray()[0]
      if (still?.phase !== "waiting_auth" || still.hand !== state.hand || still.operation !== state.operation || still.attempt !== state.attempt || active?.status !== "running" || active.effect_authorized !== 1) throw new Error("chief.machine.login_changed")
      const storedLogin = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, loginKey).toArray()[0]?.value
      if (!storedLogin || (JSON.parse(storedLogin) as LoginStart).loginId !== current.loginId) throw new Error("chief.machine.login_changed")
      // The rejected guest prompt has a settled failed ledger entry: reusing its ID
      // replays that failure. Persist the new discriminator atomically before kicking.
      save(b, run, { phase: "dispatching", operation: still.operation, attempt: (still.attempt ?? 0) + 1, hand: still.hand, cwd: still.cwd, after: 0, text: "", authRetrySafe: true })
      writeConfig(b.sql, { [resumedKey]: current.loginId })
      b.sql.exec(`DELETE FROM cb_config WHERE name = ?`, loginKey)
      b.sql.exec(`UPDATE cb_turn SET started = ? WHERE id = ?`, Date.now(), run)
      return true
    })
    if (kicked) b.kick()
    return { signedIn: true, resumed: true }
  }
  // A prior finish may have saved provider credentials but lost its reply. Only this explicit
  // owner POST can recover that outcome; GET status remains read-only. Never replay its code.
  if (await machineAuth(b.doEnv, scope, admission.machine.harness, state.cwd) === "ready") return resume()
  if (current.expiresAtMs !== undefined && current.expiresAtMs <= Date.now()) throw new Error("chief.machine.login_expired")
  if (value.code !== undefined && (value.code.length > 8192 || /[\r\n\0]/.test(value.code))) throw new Error("chief.machine.invalid_login_code")
  const signedIn = await machineLoginFinish(b.doEnv, scope, current.loginId, value.code)
  if (!signedIn) return { signedIn: false }
  return resume()
}

export interface MachineAgentPorts {
  load(): MachineState | null
  save(state: MachineState): void
  authorize(): Promise<void>
  auth(): Promise<"ready" | "signed_out" | "unknown">
  /** This port must durably deduplicate the operation, including an uncertain first response. */
  start(params: { operation: string; harness: MachineHarness; cwd: string; prompt: string }): Promise<HandReply>
  events(session: string, after: number, wait: number): Promise<HandReply<{ events: Array<StoredEvent>; last_seq: number; head_seq: number }>>
  stop(session: string): Promise<unknown>
  event(event: StoredEvent): void
  now(): number
}

/** Persist the operation before dispatch; retries reconcile the same named session and prompt. */
export const runMachineAgent = async (ports: MachineAgentPorts, hand: string, cwd: string, harness: MachineHarness, prompt: string, operation: string, deadline: number): Promise<MachineOutcome> => {
  let state = ports.load()
  if (state?.phase === "done") return { ok: true, text: state.text }
  if (state?.phase === "failed") return { ok: false, reason: state.reason ?? "chief.machine.failed" }
  if (state && state.operation !== operation) return { ok: false, reason: "chief.machine.operation_changed" }
  if (state?.phase === "waiting_auth") return { pending: "auth" }
  const authorized = async () => ports.authorize().then(() => true).catch((error: unknown) => { if (!machineRetryable(error)) throw error; return false })
  if (!await authorized()) return { pending: "provisioning" }
  if (ports.now() >= deadline) {
    if (state?.session) await ports.stop(state.session).catch(() => undefined)
    if (state) { state.phase = "failed"; state.reason = "chief.machine.timeout"; ports.save(state) }
    return { ok: false, reason: "chief.machine.timeout" }
  }
  if (!state) {
    state = { phase: "waiting_auth", operation, hand, cwd, after: 0, text: "", authRetrySafe: true }
    if (await ports.auth() === "signed_out") { ports.save(state); return { pending: "auth" } }
    // A revocation may have committed while the provider auth probe was in flight.
    if (!await authorized()) return { pending: "provisioning" }
    state.phase = "dispatching"
    ports.save(state)
  }
  if (state.phase === "dispatching") {
    const started = await ports.start({ operation: state.attempt ? `${state.operation}/auth/${state.attempt}` : state.operation, harness, cwd, prompt }).catch((error: unknown) => { if (!machineRetryable(error)) throw error; return null })
    // The guest's durable send queue owns the outcome. A lost reply retries the same operation.
    if (!started) return { pending: "provisioning" }
    if (!started.ok) {
      // An explicit refusal proves no session started. Fresh affirmative evidence can now
      // request sign-in without discarding the original prompt or retrying an uncertain start.
      if (started.error.code === "agent.start_failed" && await ports.auth() === "signed_out") { state.phase = "waiting_auth"; ports.save(state); return { pending: "auth" } }
      state.phase = "failed"; state.reason = started.error.code; ports.save(state)
      return { ok: false, reason: state.reason }
    }
    const session = (started.value as { session?: unknown } | null)?.session
    if (typeof session !== "string" || !session) return { ok: false, reason: "chief.machine.invalid_session" }
    state = { ...state, phase: "running", session }
    ports.save(state)
  }
  if (!state.session) return { ok: false, reason: "chief.machine.missing_session" }
  while (ports.now() < deadline) {
    if (!await authorized()) return { pending: "provisioning" }
    const page = await ports.events(state.session, state.after, Math.min(30_000, deadline - ports.now())).catch((error: unknown) => { if (!machineRetryable(error)) throw error; return null })
    if (!page) return { pending: "provisioning" }
    if (!page.ok) return { ok: false, reason: page.error.code }
    for (const stored of page.value.events) {
      if (stored.seq <= state.after) continue
      const event = stored.event
      state.after = stored.seq
      if (event.kind === "text") state.text += event.text
      if (event.kind === "text" || event.kind === "tool") state.authRetrySafe = false
      if (event.kind === "error") {
        // Never repeat a build that may have made progress. Legacy state without this
        // journal-derived proof also fails closed; its absent flag is not a clean attempt.
        if (event.error_kind && state.authRetrySafe === true) {
          state.phase = "waiting_auth"
          ports.save(state)
          await ports.stop(state.session).catch(() => undefined)
          return { pending: "auth" }
        }
        state.phase = "failed"; state.reason = "chief.machine.agent_error"
      }
      if (event.kind === "session_end") { state.phase = "failed"; state.reason = "chief.machine.session_ended" }
      if (event.kind === "permission") { state.phase = "failed"; state.reason = "chief.machine.permission_required" }
      if (event.kind === "turn_end" && state.phase !== "failed") state.phase = "done"
      ports.save(state)
      ports.event(stored)
      if (state.phase === "done") { await ports.stop(state.session).catch(() => undefined); return { ok: true, text: state.text } }
      if (state.phase === "failed") { await ports.stop(state.session).catch(() => undefined); return { ok: false, reason: state.reason! } }
    }
    if (page.value.last_seq > state.after) { state.after = page.value.last_seq; ports.save(state) }
  }
  await ports.stop(state.session).catch(() => undefined)
  state.phase = "failed"; state.reason = "chief.machine.timeout"; ports.save(state)
  return { ok: false, reason: state.reason }
}

/** Runs on the user's persistent machine and provider login, never on the hosted model gateway. */
export const machineTurn = async (b: ChiefBrainDO, id: string, route: MachineRoute, blocks: Array<string>): Promise<MachineOutcome> => {
  if (!b.effectsAuthorized()) {
    b.logOnce(`talk:${id}`, "talk", OWNER_APPROVAL_REQUIRED, { id: `talk:${id}`, kind: "talk", text: OWNER_APPROVAL_REQUIRED, ended_at: Date.now() })
    return { ok: true, text: OWNER_APPROVAL_REQUIRED }
  }
  const cfg = b.config()
  if (!cfg.owner || !cfg.agent) return { ok: false, reason: "chief.machine.unbound" }
  const { owner, agent } = cfg
  const startedAt = Number(b.sql.exec<{ started: number }>(`SELECT started FROM cb_turn WHERE id = ?`, id).one().started)
  if (Date.now() >= startedAt + 10 * 60_000 && !readMachineState(b.sql, id)) return { ok: false, reason: "chief.machine.timeout" }
  const record = await chiefRecord(b.doEnv, owner, agent, true)
  if (!record?.cloud_machine || record.brain_place) return { ok: false, reason: "chief.machine.binding_changed" }
  if (machineHarness(record.harness) !== route.harness) return { ok: false, reason: "chief.machine.harness_changed" }
  const scope = { ...record.cloud_machine, owner, chief: agent }
  if (!await wakeDefaultMachine(b, scope)) return { pending: "provisioning" }
  const carried = readMachineState(b.sql, id)
  if (carried && carried.hand !== defaultHandId(scope)) return { ok: false, reason: "chief.machine.binding_changed" }
  const ready = carried ? { hand: carried.hand, cwd: carried.cwd } : await ensureDefaultHand(b.doEnv, owner, agent, record.cloud_machine)
  const hand = handStub(b.doEnv, ready.hand)
  const caller = { kind: "chief" as const, user: owner, agent, conversation: b.turnConversation }
  if (!carried && !(await hand.waitOnline(30_000))) throw new Error("chief.machine.hand_offline")
  // A stricter owner policy must fail explicitly, rather than leave an unattended approval
  // prompt waiting forever. Never raise the owner's selected level while provisioning.
  const authorizeHand = () => authorizeMachineHand(b.doEnv, scope, ready.cwd)
  const direct = async (method: string, params: unknown, timeout: number, feature?: string): Promise<unknown> => {
    const admission = await b.admitted(agent, owner, false)
    if (!admission.ok || !admission.machine) throw new Error(admission.ok ? "chief.machine.binding_changed" : admission.reason)
    await authorizeHand()
    return rpc(b.doEnv, scope, method, params, timeout, feature)
  }
  // Freeze the full request before dispatch. Profile edits during provisioning, sign-in or a
  // lost reply cannot change the guest's request digest or turn a retry into different work.
  const promptKey = `machine-prompt:${id}`
  const storedPrompt = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, promptKey).toArray()[0]?.value
  const prompt = storedPrompt ?? machinePrompt(cfg, record.cloud_machine, ready.cwd, blocks)
  if (storedPrompt === undefined) writeConfig(b.sql, { [promptKey]: prompt })
  const result = await runMachineAgent({
    load: () => readMachineState(b.sql, id), save: (s) => save(b, id, s),
    authorize: async () => {
      const admission = await b.admitted(agent, owner, false)
      if (!admission.ok || !admission.machine) throw new Error(admission.ok ? "chief.machine.binding_changed" : admission.reason)
      await authorizeDefaultMachine(b.doEnv, scope)
      await authorizeHand()
    },
    auth: () => machineAuth(b.doEnv, scope, route.harness, ready.cwd),
    start: async (params) => {
      b.sql.exec(`UPDATE cb_turn SET submitted = 1, model = ? WHERE id = ?`, `machine:${route.harness}`, id)
      try { return { ok: true as const, value: await startMachineAgent(direct, params) } } catch (error) {
        if ((error as { beforePrompt?: unknown })?.beforePrompt === true) return { ok: false as const, error: { code: "agent.start_failed", message: "The machine refused to create the agent session." } }
        throw error
      }
    },
    events: async (session, after, wait) => ({ ok: true as const, value: await machineAgentEvents(direct, session, after, wait) }),
    stop: (session) => stopMachineAgent(direct, session),
    event: (stored) => {
      if (stored.event.kind !== "tool") return
      const event = stored.event
      b.announce(id, [upsertStep(b.sql, id, { id: `machine:${event.id ?? stored.seq}`, kind: "tool", status: event.status === "completed" ? "done" : "running", text: event.title ?? "Working on your machine" }, stored.at)])
    },
    now: Date.now,
  }, ready.hand, ready.cwd, route.harness, prompt, `${owner}/${agent}/${b.turnConversation}/${id}`, startedAt + 10 * 60_000)
  if ("pending" in result && result.pending === "auth") {
    // A notice is not a completed turn: retain the original input/inbox/run until sign-in finishes.
    await postText(b.doEnv, chiefPrincipal(agent, owner), b.turnConversation!, `Sign in to ${route.harness === "claude" ? "Claude" : "Codex"} to continue.`, `chief-machine-auth:${agent}:${id}`)
    await typing(b.doEnv, b.turnConversation!, agent, false)
    b.announce(id, [upsertStep(b.sql, id, { id: "machine:sign-in", kind: "note", text: `Waiting for ${route.harness} sign-in` }, Date.now())])
  } else if (!("pending" in result) && result.ok) b.logOnce(`talk:${id}`, "talk", result.text, { id: `talk:${id}`, kind: "talk", ...clip(result.text), ended_at: Date.now() })
  return result
}
