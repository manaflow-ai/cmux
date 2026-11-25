import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { mintAccessToken } from "../src/auth.ts"
import { handleChiefBrain } from "../src/chief-brain/routes.ts"
import { chiefMainConversation } from "../src/domains/user-chief.ts"
import { personalTeamIdFor, userIdFor } from "../src/domains/user.ts"
import type { Env } from "../src/env.ts"
import { sessionToken, worker } from "./pairing-harness.ts"

const AGENT = "agent_01ARZ3NDEKTSV4RRFFQ69G5FAV"
const CONVERSATION = chiefMainConversation(AGENT)
const RUN = "run_42"
const testEnv = env as unknown as Env
type Result = { ok: boolean; value?: unknown; error?: { code: string; message: string } }

const privateResponse = (response: Response) => {
  expect(response.headers.get("cache-control")).toBe("no-store")
  expect(response.headers.get("referrer-policy")).toBe("no-referrer")
}

/** Real Stack/API JWT admission; fake only the owning objects and machine transport. */
const fixture = async (subject: string) => {
  const owner = userIdFor(testEnv.STACK_PROJECT_ID, subject)
  const token = await sessionToken(subject)
  const calls: Array<{ owner: string; run: string; action: string; value?: unknown }> = []
  const brainNames: Array<string> = []
  const ownerReads: Array<string> = []
  const membershipReads: Array<string> = []
  const state = { owned: true, member: true, error: null as Error | null }
  const fake = {
    ...testEnv,
    CHIEF_BRAIN_ENABLED: "1",
    // A live mutate-own install would reach other Chief settings routes; login must still refuse it.
    USER_DO: { idFromName: (name: string) => name, get: () => ({ installGrant: async () => ({ ok: true, op_classes: ["read", "mutate-own"], kind: "daemon", email: null, email_verified: false }) }) },
    MUX_DO: { idFromName: (name: string) => name, get: () => ({ readOp: async (entity: string, principal: { user?: string }, op: string) => {
      ownerReads.push(entity)
      expect(op).toBe("mux.queue")
      return { ok: true, value: { agent: entity, owner_user: state.owned && principal.user === owner ? owner : "user_someone_else" } }
    } }) },
    CONVERSATION_DO: { idFromName: (name: string) => name, get: () => ({ readOp: async (entity: string, principal: { user?: string }, op: string) => {
      membershipReads.push(entity)
      expect(principal.user).toBe(owner)
      expect(op).toBe("conversation.history")
      return { ok: state.member }
    } }) },
    CHIEF_BRAIN_DO: {
      idFromName: (name: string) => { brainNames.push(name); return name },
      get: () => ({ machineLogin: async (user: string, run: string, action: string, value?: unknown) => {
        calls.push({ owner: user, run, action, value })
        if (state.error) throw state.error
        if (action === "status") return { waiting: true, harness: "claude", login: null }
        if (action === "start") return { loginId: "login_test", url: "https://claude.ai/oauth/authorize?code_challenge=test", needsCode: true }
        if (action === "cancel") return { cancelled: true }
        return { signedIn: true, resumed: true }
      } })
    }
  } as unknown as Env
  const request = async (method: string, body?: unknown, options: { bearer?: string | null; conversation?: string; run?: string; agent?: string } = {}) => {
    const bearer = options.bearer === undefined ? token : options.bearer
    const request = new Request(`https://api.test/v1/chiefs/${options.agent ?? AGENT}/machine-login/${options.run ?? RUN}?conversation=${options.conversation ?? CONVERSATION}`, {
      method,
      headers: { "content-type": "application/json", ...(bearer ? { authorization: `Bearer ${bearer}` } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    })
    const response = await handleChiefBrain(request, fake, options.agent ?? AGENT, "machine-login", options.run ?? RUN)
    privateResponse(response)
    return { status: response.status, json: await response.json() as Result }
  }
  return { owner, token, fake, calls, brainNames, ownerReads, membershipReads, state, request }
}

describe("pending Chief machine provider sign-in HTTP", () => {
  it("dispatches the login path independently of opencode/durable run history", async () => {
    const response = await worker.fetch(`https://api.test/v1/chiefs/${AGENT}/machine-login/${RUN}?conversation=${CONVERSATION}`)
    expect(response.status).toBe(401)
    privateResponse(response)
  })

  it("GET observes only the main-conversation brain and never starts provider sign-in", async () => {
    const f = await fixture("machine-login-status")
    const response = await f.request("GET")
    expect(response).toEqual({ status: 200, json: { ok: true, value: { waiting: true, harness: "claude", login: null } } })
    expect(f.calls).toEqual([{ owner: f.owner, run: RUN, action: "status", value: undefined }])
    expect(f.brainNames).toEqual([`${AGENT}/${CONVERSATION}`])
    expect(f.ownerReads).toEqual([AGENT])
    expect(f.membershipReads).toEqual([CONVERSATION])
  })

  it("POST forwards only the explicitly requested provider sign-in action and fields", async () => {
    const f = await fixture("machine-login-actions")
    expect((await f.request("POST", { action: "start" })).json.value).toMatchObject({ loginId: "login_test", needsCode: true })
    expect((await f.request("POST", { action: "finish", loginId: "login_test", code: "one-use-code" })).json.value).toEqual({ signedIn: true, resumed: true })
    expect((await f.request("POST", { action: "cancel", loginId: "login_test" })).json.value).toEqual({ cancelled: true })
    expect(f.calls).toEqual([
      { owner: f.owner, run: RUN, action: "start", value: {} },
      { owner: f.owner, run: RUN, action: "finish", value: { loginId: "login_test", code: "one-use-code" } },
      { owner: f.owner, run: RUN, action: "cancel", value: { loginId: "login_test" } }
    ])
  })

  it("refuses malformed POSTs before resolving any brain object", async () => {
    const f = await fixture("machine-login-invalid")
    for (const body of [null, [], {}, { action: "status" }, { action: "start", code: "secret" }, { action: "start", loginId: "login_test" }, { action: "finish" }, { action: "finish", loginId: "" }, { action: "finish", loginId: " " }, { action: "finish", loginId: 42 }, { action: "finish", loginId: "login_test", code: 42 }, { action: "finish", loginId: "login_test", code: "code\nsecret" }, { action: "finish", loginId: "login_test", extra: true }, { action: "cancel", loginId: "login_test", code: "secret" }]) {
      expect((await f.request("POST", body)).status, JSON.stringify(body)).toBe(400)
    }
    expect(f.calls).toEqual([])
    expect(f.brainNames).toEqual([])
  })

  it("requires a human session even when an install or Chief token has mutate-own", async () => {
    const f = await fixture("machine-login-human")
    expect((await f.request("POST", { action: "start" }, { bearer: null })).status).toBe(401)
    for (const claims of [{}, { agent: AGENT }, { vm: true as const }]) {
      const signed = await mintAccessToken(testEnv, { user: f.owner, team: personalTeamIdFor(f.owner), install: "inst_login_test", grant: "grant_login_test", ...claims })
      expect((await f.request("POST", { action: "start" }, { bearer: signed.token })).status).toBe(403)
    }
    expect(f.ownerReads).toEqual([])
    expect(f.membershipReads).toEqual([])
    expect(f.brainNames).toEqual([])
  })

  it("hides a different owner, a different conversation, a missing membership and subruns", async () => {
    const f = await fixture("machine-login-hidden")
    f.state.owned = false
    const hidden = await f.request("GET")
    expect(hidden).toEqual({ status: 404, json: { ok: false, error: { code: "not_found", message: "no such run" } } })
    expect(f.membershipReads).toEqual([])
    f.state.owned = true
    expect(await f.request("GET", undefined, { conversation: "conv_01ARZ3NDEKTSV4RRFFQ69G5FAW" })).toEqual(hidden)
    expect(f.membershipReads).toEqual([])
    f.state.member = false
    expect(await f.request("GET")).toEqual(hidden)
    expect(await f.request("GET", undefined, { run: "sub_42" })).toEqual(hidden)
    expect(await f.request("GET", undefined, { agent: "agent_invalid" })).toEqual(hidden)
    expect(f.brainNames).toEqual([])
  })

  it("maps pending-state and access changes without exposing provider/guest errors", async () => {
    const f = await fixture("machine-login-errors")
    for (const [message, status, code] of [
      ["chief.machine.login_not_pending", 404, "not_found"],
      ["chief.machine.login_changed", 409, "chief.machine.login_changed"],
      ["chief.machine.login_busy", 409, "chief.machine.login_busy"],
      ["chief.machine.login_expired", 410, "chief.machine.login_expired"],
      ["chief.machine.invalid_login_code", 400, "validation.invalid"],
      ["hand.revoked", 403, "auth.forbidden"],
      ["chief.machine.login_refused", 403, "auth.forbidden"],
      ["chief.machine.binding_changed", 403, "auth.forbidden"],
      ["provider returned secret=never-return-this", 503, "chief.machine.login_unavailable"]
    ] as const) {
      f.state.error = new Error(message)
      const response = await f.request("POST", { action: "start" })
      expect(response.status).toBe(status)
      expect(response.json.error?.code).toBe(code)
      expect(JSON.stringify(response.json)).not.toContain("never-return-this")
    }
  })

  it("keeps disabled-route and method errors private before resolving objects", async () => {
    const f = await fixture("machine-login-disabled")
    expect((await f.request("PUT", {})).status).toBe(405)
    Object.assign(f.fake, { CHIEF_BRAIN_ENABLED: "0" })
    expect((await f.request("GET")).status).toBe(404)
    expect(f.ownerReads).toEqual([])
    expect(f.brainNames).toEqual([])
  })
})
