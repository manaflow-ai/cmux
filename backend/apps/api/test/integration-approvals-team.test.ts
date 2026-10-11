import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { memberUpsert, TABLE_MEMBER } from "../src/domains/team-members.ts"
import { approvalReader } from "../src/integrations/approval-route.ts"
import { insertApproval, APPROVAL_TTL_MS } from "../src/integrations/approvals.ts"
import { approvalDigest } from "../src/integrations/approval-gate.ts"

/**
 * G8 approvals across teams: an op of a team's agent waits in that team's ConnectionDO, while the
 * person's session token carries their personal team. `integration.approval.get` routes by the
 * team of the person's own feed request, and only when TeamDO lists the person as a member.
 */
const testEnv = env as unknown as Record<string, any>
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>

const sessionToken = async (stackUser: string) =>
  new SignJWT({ email: `${stackUser}@example.com`, name: stackUser })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(stackUser)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, token: string, body: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify(body) })
  return { status: res.status, json: (await res.json()) as any }
}
const read = (token: string, name: string, params: unknown = {}) => call("/v1/read", token, { op: name, params })
const signIn = async (who: string) => {
  const token = await sessionToken(who)
  const ensured = (await call("/v1/ops", token, { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" })).json.value
  return { token, user: ensured.id as string, team: ensured.personal_team as string, name: who }
}

/**
 * A request that `team`'s agent made for `user`, stored in that team's ConnectionDO and posted to
 * the user's feed by `posterTeam`'s ConnectionDO (default the same team), naming `promptTeam`.
 */
const pendingIn = async (team: string, user: string, { promptTeam = team, posterTeam = team }: { promptTeam?: string; posterTeam?: string } = {}) => {
  const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
  const params = { connection: "conn_team", channel: "C9", text: "team secret text" }
  const digest = approvalDigest("slack.post_as_bot", params)
  const now = Date.now()
  await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (_i, st) =>
    insertApproval(st.storage.sql, {
      request,
      identity: `install:agent-${request}`,
      idempotency_key: `k-${request}`,
      user,
      connection: "conn_team",
      op: "slack.post_as_bot",
      params,
      params_hash: digest,
      digest,
      principal: { identity: `install:agent-${request}`, kind: "install", user, team },
      target: "C9",
      summary: "",
      created_at: now,
      expires_at: now + APPROVAL_TTL_MS
    })
  )
  const prompt = { action: { type: "tool", tool: "slack.post_as_bot", summary: "slack.post_as_bot to C9", risk: "send-external", input: { approval: { team: promptTeam, request, digest }, connection: "conn_team", target: "C9", summary: "" } }, scopes: ["once"] }
  const feed = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(user))
  const posted = await feed.integrationApproval(user, posterTeam, prompt, APPROVAL_TTL_MS, `approval:${request}`)
  expect(posted.ok).toBe(true)
  return request
}

const joinTeam = (team: string, member: { user: string; name: string }) =>
  inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
    instance.boundEngine.rows.apply([memberUpsert({ user: member.user, role: "member", display_name: member.name })])
  })
const leaveTeam = (team: string, member: { user: string }) =>
  inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
    instance.boundEngine.rows.apply([{ table: TABLE_MEMBER, op: "delete", key: member.user }])
  })

describe("integration.approval.get across teams (G8)", { timeout: 60_000 }, () => {
  it("a member reads a request that another team's agent made; a non-member does not", async () => {
    const owner = await signIn("g8x-owner")
    const member = await signIn("g8x-member")
    const request = await pendingIn(owner.team, member.user)
    // Not a member yet: the request stays invisible.
    expect((await read(member.token, "integration.approval.get", { request })).status).toBe(400)
    await joinTeam(owner.team, member)
    const view = await read(member.token, "integration.approval.get", { request })
    expect(view.status).toBe(200)
    expect(view.json.value).toMatchObject({ request, op: "slack.post_as_bot", state: "pending", params: { text: "team secret text" } })
    // The team owner's session is not the person asked: the row's user still decides.
    expect((await read(owner.token, "integration.approval.get", { request })).status).toBe(400)
  })

  it("routes only by the team whose ConnectionDO posted the feed request, never by a team named in the prompt alone", async () => {
    const owner = await signIn("g8x-owner2")
    const member = await signIn("g8x-member2")
    const other = await signIn("g8x-other2")
    await joinTeam(other.team, member)
    // The row waits in `other`'s ConnectionDO and the prompt names `other`, but `owner`'s ConnectionDO posted it.
    const request = await pendingIn(other.team, member.user, { promptTeam: other.team, posterTeam: owner.team })
    expect((await read(member.token, "integration.approval.get", { request })).status).toBe(400)
    // The same request posted by `other` itself is readable.
    const genuine = await pendingIn(other.team, member.user)
    expect((await read(member.token, "integration.approval.get", { request: genuine })).status).toBe(200)
  })

  it("a member who left the team no longer reads its requests", async () => {
    const owner = await signIn("g8x-owner3")
    const member = await signIn("g8x-member3")
    await joinTeam(owner.team, member)
    const request = await pendingIn(owner.team, member.user)
    expect((await read(member.token, "integration.approval.get", { request })).status).toBe(200)
    await leaveTeam(owner.team, member)
    expect((await read(member.token, "integration.approval.get", { request })).status).toBe(400)
  })

  it("a team that enforces SSO is reached only with that team's SSO session", async () => {
    const owner = await signIn("g8x-owner4")
    const member = await signIn("g8x-member4")
    await joinTeam(owner.team, member)
    const request = await pendingIn(owner.team, member.user)
    const reader = { kind: "session" as const, identity: `session:${member.user}`, user: member.user, team: member.team, stack_session: "rt_1", stack_user_id: "g8x-member4" }
    const rules = async () => ({ sso_required: true, minimum_version: null, allowed_classes: [] })
    const withoutSso = await approvalReader(testEnv as any, reader, { request }, { rules, sso: async (_e, p) => p })
    expect(withoutSso.team).toBe(member.team)
    const withSso = await approvalReader(testEnv as any, reader, { request }, { rules, sso: async (_e, p, team) => ({ ...p, sso_team: team }) })
    expect(withSso).toMatchObject({ team: owner.team, sso_team: owner.team })
  })
})
