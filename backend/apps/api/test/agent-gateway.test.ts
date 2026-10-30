import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Http } from "../src/integrations/providers.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { mintAccessToken } from "../src/auth.ts"
import type { Env } from "../src/env.ts"

type Reply = { ok: boolean; op: string; value?: unknown; error?: { code: string; details?: { request?: string } }; replayed: boolean }
type Gateway = { dispatchIssueComment(input: Input): Promise<Reply> }
type Input = { authorization: string; team: string; connectionId: string; repo: string; issue: number; body: string; mcpSessionId: string; requestId: string; toolInvocationId: string }

const e = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const gateway = (exports as unknown as { AgentGateway?: Gateway }).AgentGateway
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
let seq = 0

const tokenFor = async (sub: string) => {
  const key = await importJWK(JSON.parse(e.STACK_TEST_PRIVATE_JWK) as JWK, "ES256")
  return new SignJWT({ email: `${sub}@example.test`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" }).setIssuer(`https://api.stack-auth.com/api/v1/projects/${e.STACK_PROJECT_ID}`)
    .setAudience(e.STACK_PROJECT_ID).setSubject(sub).setIssuedAt().setExpirationTime("10m").sign(key)
}
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const op = (token: string, name: string, params: unknown, key = crypto.randomUUID(), origin = "user") => call("/v1/ops", token, { op: name, params, idempotency_key: key, origin })
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } })

const setup = async (label: string) => {
  const sub = `agent-gateway-${label}-${++seq}`
  const session = await tokenFor(sub)
  const ensured = (await op(session, "user.ensure", {})).json.value
  const user = ensured.id as string
  const team = ensured.personal_team as string
  const connect = await op(session, "integration.connect", { provider: "github", sharing: "team" })
  const connectionId = connect.json.value.connection.id as string
  const state = new URL(connect.json.value.authorize_url as string).searchParams.get("state")!
  const installation = 400 + seq
  const calls: Array<{ url: string; body: string }> = []
  let mode: "normal" | "lost" | "race" = "normal"
  const connection = e.CONNECTION_DO.get(e.CONNECTION_DO.idFromName(team))
  const http: Http = async (req) => {
    const body = await req.clone().text()
    calls.push({ url: req.url, body })
    if (req.url.startsWith("https://github.com/login/oauth/access_token")) return json({ access_token: "ghu_synthetic" })
    if (req.url.startsWith("https://api.github.com/user/installations/")) return json({ repositories: [{ full_name: "acme/web" }] })
    if (req.url.startsWith("https://api.github.com/user/installations")) return json({ installations: [{ id: installation, account: { login: "acme", type: "Organization" }, permissions: { issues: "write" } }] })
    if (req.url.startsWith(`https://api.github.com/app/installations/${installation}/access_tokens`)) {
      if (mode === "race") await inDO(connection, async (instance) => { instance.boundEngine.currentState.connections[connectionId].resources = { repos: ["acme/other"] } })
      return json({ token: "ghs_synthetic", expires_at: new Date(Date.now() + 3_600_000).toISOString() }, 201)
    }
    if (req.url.includes("/comments")) {
      if (mode === "lost") { calls.push({ url: "provider-accepted", body }); throw new Error("ack lost after provider accepted") }
      return json({ id: 9000 + calls.length, html_url: `https://github.com/acme/web/issues/7#issuecomment-${9000 + calls.length}` }, 201)
    }
    return new Response("not found", { status: 404 })
  }
  await inDO(connection, async (instance) => { instance.http = http })
  expect((await op(session, "integration.complete", { state, code: "synthetic", installation_id: String(installation) })).json.ok).toBe(true)
  const feed = e.FEED_DO.get(e.FEED_DO.idFromName(user))
  const items = async () => (await read(session, "feed.list")).json.value.items.filter((x: any) => x.kind === "approve" && x.poster.kind === "integration")
  const answer = (item: string, decision: "allow" | "deny") => op(session, "feed.answer", { item, answer: { decision, ...(decision === "allow" ? { scope: "once" } : {}) } })
  const input = (overrides: Partial<Input> = {}): Input => ({ authorization: `Bearer ${session}`, team, connectionId, repo: "acme/web", issue: 7, body: "synthetic comment", mcpSessionId: "session-1", requestId: "request-1", toolInvocationId: "tool-1", ...overrides })
  return { session, user, team, connectionId, connection, feed, calls, items, answer, input, setMode: (next: typeof mode) => { mode = next } }
}

describe("hosted MCP agent gateway", { timeout: 60_000 }, () => {
  it("requires the dev named entrypoint, gates agents, and keeps human direct calls separate", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const s = await setup("pending")
    const pending = await gateway.dispatchIssueComment(s.input({ requestId: "pending" }))
    expect(pending).toMatchObject({ ok: false, error: { code: "approval.pending" } })
    expect(s.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
    expect(JSON.stringify(pending)).not.toContain("ghs_synthetic")
    expect((await op(s.session, "github.issue.comment", { connection: s.connectionId, repo: "acme/web", issue: 7, body: "human direct" })).json.ok).toBe(true)
    expect(s.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(1)
  })

  it("rejects an unregistered install JWT before requesting approval", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const s = await setup("missing-install")
    const token = await mintAccessToken(env as Env, { user: s.user, team: s.team, install: "inst_unknown", grant: "grant_unknown" })
    expect((await gateway.dispatchIssueComment(s.input({ authorization: `Bearer ${token.token}` }))).error?.code).toBe("auth.forbidden")
    expect(await s.items()).toHaveLength(0)
    expect(s.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
  })

  it("rechecks the source install when approval is executed", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const s = await setup("revoked-install")
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair
    const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey) as JsonWebKey
    const reg = await op(s.session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y }, kind: "mac", name: "gateway", device_name: "gateway", platform: "macos" })
    expect(reg.json.ok).toBe(true)
    const token = await mintAccessToken(env as Env, { user: s.user, team: s.team, install: reg.json.value.id, grant: reg.json.value.grant })
    const pending = await gateway.dispatchIssueComment(s.input({ authorization: `Bearer ${token.token}` }))
    expect(pending.error?.code).toBe("approval.pending")
    expect((await op(s.session, "install.revoke", { install: reg.json.value.id })).json.ok).toBe(true)
    const [item] = await s.items()
    expect((await s.answer(item.id, "allow")).json.ok).toBe(true)
    await fireAlarm(s.feed)
    expect(s.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
  })

  it("approves exact args once, replays the durable receipt, and rejects changed args", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const s = await setup("approve")
    const input = s.input({ requestId: "approve" })
    const pending = await gateway.dispatchIssueComment(input)
    const request = pending.error?.details?.request
    expect(request).toMatch(/^apr_/)
    const [item] = await s.items()
    expect((await s.answer(item.id, "allow")).json.ok).toBe(true)
    await fireAlarm(s.feed)
    expect(s.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(1)
    const done = await gateway.dispatchIssueComment(input)
    expect(done).toMatchObject({ ok: true, replayed: true, value: { id: expect.any(Number), url: expect.stringContaining("issuecomment-") } })
    expect((await gateway.dispatchIssueComment({ ...input, body: "changed" })).error?.code).toBe("idempotency.conflict")
    await inDO(s.connection, async (instance) => {
      // OAuth completion has its own ledger row; only the approved comment must be
      // written once across execution, replay, and the changed-argument refusal.
      expect(instance.ctx.storage.sql.exec("SELECT status FROM external_calls WHERE op = ?", "github.issue.comment").toArray()).toEqual([{ status: "done" }])
      expect(JSON.stringify(instance.ctx.storage.sql.exec("SELECT * FROM external_calls").toArray())).not.toContain("ghs_synthetic")
    })
    expect(JSON.stringify(done)).not.toContain("ghs_synthetic")
  })

  it("keeps deny, expiry, wrong caller/team, and revoked pending requests at zero POSTs", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const deny = await setup("deny")
    const denied = await gateway.dispatchIssueComment(deny.input({ requestId: "deny" }))
    const [denyItem] = await deny.items(); await deny.answer(denyItem.id, "deny"); await fireAlarm(deny.feed)
    expect((await gateway.dispatchIssueComment(deny.input({ requestId: "deny" }))).error?.code).toBe("approval.denied")
    expect(deny.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
    const expire = await setup("expire")
    const expired = await gateway.dispatchIssueComment(expire.input({ requestId: "expire" }))
    await inDO(expire.connection, async (instance) => instance.ctx.storage.sql.exec("UPDATE integration_approvals SET expires_at = 1 WHERE request = ?", expired.error?.details?.request))
    expect((await gateway.dispatchIssueComment(expire.input({ requestId: "expire" }))).error?.code).toBe("approval.expired")
    const other = await setup("wrong")
    expect((await gateway.dispatchIssueComment({ ...other.input({ team: expire.team, connectionId: expire.connectionId, requestId: "wrong" }), authorization: `Bearer ${other.session}` })).error?.code).toBe("auth.forbidden")
    expect((await gateway.dispatchIssueComment(other.input({ team: "team_00000000000000000000", requestId: "wrong-team" }))).ok).toBe(false)
    const revoked = await setup("revoke")
    const revPending = await gateway.dispatchIssueComment(revoked.input({ requestId: "revoke" }))
    await op(revoked.session, "integration.revoke", { connection: revoked.connectionId })
    const [revItem] = await revoked.items(); await revoked.answer(revItem.id, "allow"); await fireAlarm(revoked.feed)
    expect(revPending.error?.code).toBe("approval.pending")
    expect(revoked.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
  })

  it("does not replay a lost provider acknowledgement and rechecks scope before POST", async () => {
    expect(gateway).toBeDefined()
    if (!gateway) return
    const lost = await setup("lost")
    const input = lost.input({ requestId: "lost" })
    await gateway.dispatchIssueComment(input); const [item] = await lost.items(); await lost.answer(item.id, "allow"); lost.setMode("lost"); await fireAlarm(lost.feed)
    const uncertain = await gateway.dispatchIssueComment(input)
    expect(uncertain).toMatchObject({ ok: false, replayed: true, error: { code: "mutation.indeterminate" } })
    expect(lost.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(1)
    const race = await setup("race")
    await gateway.dispatchIssueComment(race.input({ requestId: "race" })); const [raceItem] = await race.items(); await race.answer(raceItem.id, "allow"); race.setMode("race"); await fireAlarm(race.feed)
    expect(race.calls.filter((x) => x.url.includes("/comments"))).toHaveLength(0)
  })
})
