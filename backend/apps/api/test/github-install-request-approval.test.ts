// An organization member's GitHub App install request, then an owner's approval (integrations/github-install-requests.ts):
// the request's code proves who asked, and the approval's `installation.created` (its `requester`) tells that person
// with a feed notice and an `integration.changed` on their watching feed socket. Nothing links by itself. GitHub is faked.
import { env, exports } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { approvalFrame, approvalNotice, installApprovalOf } from "../src/integrations/github-install-requests.ts"
import { signedInWithInstall } from "./cloud-bind-support.ts"
import { fakeGitHub, inDO, ok, op, read, testEnv } from "./github-token-support.ts"

const worker = (exports as unknown as { default: Fetcher }).default

const hmac = async (secret: string, msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}
/** GitHub's `installation.created` for installation 123 on acme, approved for `requester` (null: a direct install). */
const approved = async (requester: number | null, delivery: string = crypto.randomUUID()) => {
  const body = JSON.stringify({ action: "created", installation: { id: 123, account: { login: "acme", type: "Organization" } }, requester: requester === null ? null : { id: requester, login: "member" }, sender: { id: 1, login: "owner" } })
  const res = await worker.fetch("https://api.test/v1/hooks/github", {
    method: "POST",
    headers: { "x-hub-signature-256": `sha256=${await hmac((env as any).GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": delivery, "x-github-event": "installation" },
    body
  })
  expect(res.status).toBe(200)
}

const openFeed = async (token: string, user: string) => {
  const res = await worker.fetch("https://api.test/v1/wire/feed", { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": "cmux.wire.v1", authorization: `Bearer ${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  const waiters: Array<() => void> = []
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    waiters.splice(0).forEach((w) => w())
  })
  ws.accept()
  const until = async (pred: (fs: Array<any>) => boolean) => {
    while (!pred(frames)) await new Promise<void>((r) => waiters.push(r))
  }
  ws.send(JSON.stringify({ t: "subscribe", stream: `feed:${user}`, pending: [] }))
  await until((fs) => fs.some((f) => f.t === "snapshot"))
  ws.send(JSON.stringify({ t: "integration.watch", provider: "github" }))
  await until((fs) => fs.some((f) => f.t === "integration.watching"))
  return { ws, frames, until }
}

const notices = async (session: string) =>
  ((await read(session, "feed.list", {})).body.value?.items ?? []).filter((i: any) => i.dedupe_key?.startsWith("github-install-approved:"))

/** A member's request: GitHub comes back with a code and no installation; the code's user is `githubId`. */
const request = async (session: string, team: string, githubId: number | null, code: string | undefined = "c") => {
  const gh = fakeGitHub()
  if (githubId === null) gh.routes["https://api.github.com/user"] = () => ok({ message: "Bad credentials" }, 401)
  else gh.routes["https://api.github.com/user"] = () => ok({ id: githubId, login: "member" })
  await inDO(testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(team)), async (instance) => void (instance.http = gh.http))
  const connect = await op(session, "integration.connect", { provider: "github", sharing: "team" })
  const state = new URL(connect.body.value.authorize_url).searchParams.get("state")!
  const done = await op(session, "integration.complete", { state, ...(code ? { code } : {}), setup_action: "request" })
  expect(done.body.ok).toBe(false)
  expect(done.body.error.message).toContain("When an owner approves it, choose Connect GitHub in cmux again")
  return gh
}

describe("installApprovalOf: which deliveries are an approved request", () => {
  it("only installation.created with a requester", () => {
    const d = (event: string, payload: unknown) => ({ event, delivery_id: "github:d", payload })
    expect(installApprovalOf(d("installation.created", { installation: { id: 5, account: { login: "acme" } }, requester: { id: 9 } }))).toEqual({ requester_id: 9, installation_id: 5, account: "acme", delivery_id: "github:d" })
    expect(installApprovalOf(d("installation.created", { installation: { id: 5 }, requester: null }))).toBeNull()
    expect(installApprovalOf(d("installation.deleted", { installation: { id: 5 }, requester: { id: 9 } }))).toBeNull()
    expect(installApprovalOf(d("installation.created", { installation: { id: 5 }, requester: { id: "9" } }))).toBeNull()
  })

  it("the notice is a plain notice and the frame is an integration.changed every client already re-reads on", () => {
    const a = { requester_id: 9, installation_id: 5, account: "acme", delivery_id: "github:d" }
    expect(approvalNotice(a)).toMatchObject({ type: "notice", kind: "notice", title: "acme approved the cmux GitHub App", dedupe_key: "github-install-approved:5", thread: "github-install-request" })
    expect("prompt" in approvalNotice(a)).toBe(false)
    expect(approvalFrame(a)).toEqual({ t: "integration.changed", provider: "github", changes: [], more: true, installation: { id: 5, account: "acme", approved: true } })
  })
})

describe("an owner's approval reaches the member who asked (workerd)", { timeout: 60_000 }, () => {
  it("the requester's code is exchanged once; the approval posts one notice and one integration.changed; nothing links", async () => {
    const a = await signedInWithInstall("gh-request-approved", "mac")
    const gh = await request(a.session, a.team, 7001)
    // One code exchange and one GET /user: who asked, nothing else.
    expect(gh.calls.map((c) => c.url)).toEqual(["https://github.com/login/oauth/access_token", "https://api.github.com/user"])
    const wire = await openFeed(a.installToken, a.user)

    // Another member's approval, and a direct install, tell this person nothing.
    await approved(7002)
    await approved(null)
    expect(await notices(a.session)).toHaveLength(0)

    await approved(7001)
    await wire.until((fs) => fs.some((f) => f.t === "integration.changed"))
    expect(wire.frames.filter((f) => f.t === "integration.changed")).toEqual([{ t: "integration.changed", provider: "github", changes: [], more: true, installation: { id: 123, account: "acme", approved: true } }])
    const items = await notices(a.session)
    expect(items).toHaveLength(1)
    expect(items[0]).toMatchObject({ type: "notice", title: "acme approved the cmux GitHub App", poster: { kind: "integration", label: "GitHub" }, priority: "high" })
    // Never linked: the person's own Connect proves their access.
    const conns = (await read(a.session, "integration.list")).body.value.connections as Array<{ provider: string; status: string }>
    expect(conns.filter((c) => c.provider === "github" && c.status === "active")).toHaveLength(0)

    // A second approval (GitHub's redelivery, or a reinstall) tells no one again.
    await approved(7001)
    expect(await notices(a.session)).toHaveLength(1)
    wire.ws.close()
  })

  it("a request whose code proves no GitHub user records nothing", async () => {
    const a = await signedInWithInstall("gh-request-no-user", "mac")
    await request(a.session, a.team, null)
    await approved(7003)
    expect(await notices(a.session)).toHaveLength(0)
    const b = await signedInWithInstall("gh-request-no-code", "mac")
    const gh = await request(b.session, b.team, 7004, undefined)
    expect(gh.calls).toHaveLength(0)
    await approved(7004)
    expect(await notices(b.session)).toHaveLength(0)
  })
})
