import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import type { Principal } from "@cmux/ownership"
import { feedDomain, initialFeedState } from "../src/domains/feed.ts"
import { memberUpsert, TABLE_MEMBER } from "../src/domains/team-members.ts"
import { approvalDigest, deliverAnswers } from "../src/integrations/approval-gate.ts"
import { answerAdmitted, answerPrincipal } from "../src/integrations/approval-route.ts"
import { approvalByRequest, insertApproval, APPROVAL_TTL_MS } from "../src/integrations/approvals.ts"
import { run, U } from "./feed-harness.ts"

/**
 * G8 answers across teams (cx-3bi.16.12): the same checks as integration.approval.get hold when
 * the answer arrives. A person removed from the team, or a session without the team's SSO when
 * the team enforces it, cannot approve: the request ends denied and nothing runs.
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
const signIn = async (who: string) => {
  const token = await sessionToken(who)
  const res = await worker.fetch("https://api.test/v1/ops", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "user" }) })
  const v = ((await res.json()) as any).value
  return { user: v.id as string, team: v.personal_team as string, name: who }
}
const membership = (team: string, user: string, join: boolean) =>
  inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
    instance.boundEngine.rows.apply([join ? memberUpsert({ user, role: "member", display_name: user }) : { table: TABLE_MEMBER, op: "delete", key: user }])
  })

const noSso = async () => ({ sso_required: false, minimum_version: null, allowed_classes: [] })
const ssoRequired = async () => ({ sso_required: true, minimum_version: null, allowed_classes: [] })

/** Stores a pending request of `team` for `user`, then delivers the person's allow answer through the gate; returns what ran. */
const answerOnce = async (team: string, user: string, answer: { sso_team?: string }, rules = noSso) =>
  inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (_i, st) => {
    const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
    const params = { connection: "conn_team", channel: "C9", text: "team secret text" }
    const digest = approvalDigest("slack.post_as_bot", params)
    const now = Date.now()
    insertApproval(st.storage.sql, { request, identity: `install:agent-${request}`, idempotency_key: `k-${request}`, user, connection: "conn_team", op: "slack.post_as_bot", params, params_hash: digest, digest, principal: { identity: `install:agent-${request}`, kind: "install", user, team }, target: "C9", summary: "", created_at: now, expires_at: now + APPROVAL_TTL_MS })
    let runs = 0
    await deliverAnswers(
      st.storage.sql,
      `feed:${user}`,
      [{ id: 1, params: { request, decision: "allow", digest, ...answer } }],
      async () => {
        runs++
        return { ok: true, op: "slack.post_as_bot", value: {}, transaction: "", idempotency_key: "", replayed: false, stream: "", sequence: 0 }
      },
      (row, p) => answerAdmitted(testEnv as any, team, row.user, p, { rules, sso: async (_e, q) => q })
    )
    return { runs, state: approvalByRequest(st.storage.sql, request)!.state }
  })

describe("G8 answers re-check the team at answer time", { timeout: 60_000 }, () => {
  it("a member's approval runs once; after the member left the team it ends denied and nothing runs", async () => {
    const owner = await signIn("g8a-owner")
    const member = await signIn("g8a-member")
    await membership(owner.team, member.user, true)
    expect(await answerOnce(owner.team, member.user, {})).toEqual({ runs: 1, state: "done" })
    await membership(owner.team, member.user, false)
    expect(await answerOnce(owner.team, member.user, {})).toEqual({ runs: 0, state: "denied" })
  })

  it("a team that enforces SSO accepts only an answer from that team's SSO session", async () => {
    const owner = await signIn("g8a-owner2")
    const member = await signIn("g8a-member2")
    await membership(owner.team, member.user, true)
    expect(await answerOnce(owner.team, member.user, {}, ssoRequired)).toEqual({ runs: 0, state: "denied" })
    expect(await answerOnce(owner.team, member.user, { sso_team: "team_someoneelse000000" }, ssoRequired)).toEqual({ runs: 0, state: "denied" })
    expect(await answerOnce(owner.team, member.user, { sso_team: owner.team }, ssoRequired)).toEqual({ runs: 1, state: "done" })
  })

  it("the feed carries the answering session's SSO team for the posting team to check", () => {
    const team = "team_xxxxxxxxxxxxxxxxxxxx"
    const poster: Principal = { identity: `system:connections:${team}`, kind: "system", user: U }
    const digest = `sha256:${"a".repeat(64)}`
    const request = `apr_${"b".repeat(32)}`
    const prompt = { action: { type: "tool", tool: "slack.post_as_bot", summary: "slack.post_as_bot to C9", risk: "send-external", input: { approval: { team, request, digest } } }, scopes: ["once"] }
    const posted = run(initialFeedState(), poster, "feed.post", { type: "request", kind: "approve", title: "Approve an action by an agent", prompt, poster: { kind: "integration", label: "Integrations" } }, 1_000, "tx_post", "script")
    expect(posted.ok).toBe(true)
    if (!posted.ok) return
    const session: Principal = { identity: `session:${U}`, kind: "session", user: U, sso_team: team }
    const r = feedDomain.reduce(posted.state, "feed.answer", { item: posted.value.item.id, answer: { decision: "allow", scope: "once" } }, { principal: session, origin: "user", now: 2_000, tx: "tx_ans", newId: () => "x" })
    expect(r.ok && r.outbox?.[0]?.payload).toMatchObject({ request, decision: "allow", digest, sso_team: team })
  })

  it("the Worker adds the posting team's SSO session to a cross-team answer, and only that", async () => {
    const owner = await signIn("g8a-owner3")
    const member = await signIn("g8a-member3")
    const feed = testEnv.FEED_DO.get(testEnv.FEED_DO.idFromName(member.user))
    const request = `apr_${crypto.randomUUID().replace(/-/g, "")}`
    const prompt = { action: { type: "tool", tool: "slack.post_as_bot", summary: "slack.post_as_bot to C9", risk: "send-external", input: { approval: { team: owner.team, request, digest: `sha256:${"c".repeat(64)}` } } }, scopes: ["once"] }
    const posted = await feed.integrationApproval(member.user, owner.team, prompt, APPROVAL_TTL_MS, `approval:${request}`)
    const session: Principal = { identity: `session:${member.user}`, kind: "session", user: member.user, team: member.team, stack_session: "rt_1", stack_user_id: "g8a-member3" }
    const confirmed = await answerPrincipal(testEnv as any, session, "feed.answer", { item: posted.item }, { rules: noSso, sso: async (_e, q, team) => ({ ...q, sso_team: team }) })
    expect(confirmed.sso_team).toBe(owner.team)
    // Other ops and personal-team items pass through untouched.
    expect(await answerPrincipal(testEnv as any, session, "feed.read", { item: posted.item }, { rules: noSso, sso: async (_e, q, team) => ({ ...q, sso_team: team }) })).toBe(session)
  })
})
