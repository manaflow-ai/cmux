import type { Env } from "../env.ts"
import { verifyGitHub, verifyLinear, verifySlack, type Provider, type Verified } from "./providers.ts"
import { readRawBody } from "./verify.ts"
import { requesterKey, userIdOf } from "../integrations/github-handoffs.ts"

/**
 * Provider webhooks: `POST /v1/hooks/{github,slack,linear}`. Verify first
 * (no DO call before), then fan out to every team connection linked to the
 * delivery's provider account. A provider without its signing secret answers
 * 503 so it retries after setup.
 */

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })

const secretFor = (env: Env, provider: Provider) =>
  provider === "github" ? env.GITHUB_WEBHOOK_SECRET : provider === "slack" ? env.SLACK_SIGNING_SECRET : env.LINEAR_WEBHOOK_SECRET

export const handleProviderHook = async (request: Request, env: Env, provider: Provider): Promise<Response> => {
  if (request.method !== "POST") return json(405, { ok: false, code: "method.not_allowed" })
  const secret = secretFor(env, provider)
  if (!secret) return json(503, { ok: false, code: "integration.not_configured" })
  const body = await readRawBody(request)
  if (!body.ok) return json(body.status, { ok: false, code: "validation.invalid", message: body.message })
  const now = Date.now()
  const v: Verified =
    provider === "github"
      ? await verifyGitHub(secret, request.headers, body.text)
      : provider === "slack"
        ? await verifySlack(secret, request.headers, body.text, now)
        : await verifyLinear(secret, request.headers, body.text, now)
  if (!v.ok) return json(v.status, { ok: false, code: v.status === 401 ? "auth.unauthenticated" : "validation.invalid", message: v.message })
  if ("reply" in v) return json(v.reply.status, v.reply.body)
  const d = v.delivery
  const links = await env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(d.account)).list()
  let runs = 0
  for (const { team, connection } of links) {
    const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team))
    const r = (await stub.ingest(team, connection, { provider, account: d.account, delivery_id: d.delivery_id, event: d.event, payload: d.payload })) as { runs: number }
    runs += r.runs
  }
  // An organization owner approved a member's install request: the installation is new (nothing links it yet), and the
  // team that recorded the request from that GitHub user (`requester`, a signed field) links it (ConnectionDO.githubRequestApproved).
  const requester = d.event === "installation.created" ? userIdOf((d.payload as { requester?: unknown } | null)?.requester) : undefined
  let approved = 0
  if (requester !== undefined) {
    for (const { team, connection } of await env.ACCOUNT_INDEX_DO.get(env.ACCOUNT_INDEX_DO.idFromName(requesterKey(requester))).list()) {
      const stub = env.CONNECTION_DO.get(env.CONNECTION_DO.idFromName(team))
      if ((await stub.githubRequestApproved(team, connection, { provider, account: d.account, delivery_id: d.delivery_id, event: d.event, payload: d.payload })) === "linked") approved += 1
    }
  }
  return json(200, { ok: true, delivery: d.delivery_id, connections: links.length, runs, ...(requester !== undefined ? { approved } : {}) })
}
