import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import { fireAlarm } from "./setup/alarm.ts"
import { memberUpsert } from "../src/domains/team-members.ts"
import { createHash } from "node:crypto"

/**
 * The Claude Code route of a Cloud Chief (chief-brain-cc/): for an owner on the paid-model list, each turn
 * runs as Claude Code in its own Freestyle VM (joined to the tailnet with a one-use key from the Tailscale
 * API) and streams back to POST /v1/chief-cc/<agent>/<conversation>/notes with a per-turn token; the reply
 * is posted as the Chief, the VM is deleted by its exact id, the team needs no Cloud credits, and the next
 * turn's input carries the earlier reply (the Chief's memory). Freestyle and the Tailscale API are faked at
 * their HTTP boundary; the fake VM plays the turn machine (backend/chief-cc/image/run.mjs) by posting notes
 * to the Worker. One file on purpose: it replaces globalThis.fetch and the route's settings.
 */
type TestEnv = Record<string, string | undefined> & { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; USER_DO: DurableObjectNamespace; TEAM_DO: DurableObjectNamespace }
const testEnv = env as unknown as TestEnv
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as <T>(stub: unknown, fn: (instance: any, state: DurableObjectState) => Promise<T>) => Promise<T>
const sessionToken = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const http = async (method: string, path: string, token: string, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, { method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  return { status: res.status, text: await res.clone().text(), json: (await res.json().catch(() => null)) as any }
}
const op = async (token: string, name: string, params: unknown, key: string = crypto.randomUUID()) => (await http("POST", "/v1/ops", token, { op: name, params, idempotency_key: key, origin: "user" })).json
const history = async (token: string, conversation: string) => (await http("POST", "/v1/read", token, { op: "conversation.history", params: { conversation, limit: 50 } })).json.value.messages as Array<any>

const SETTINGS = { CHIEF_CC_ENABLED: "1", CHIEF_CC_SNAPSHOT: "sh-test-chief-cc", CHIEF_CC_FREESTYLE_API_KEY: "test-freestyle-key-not-real", CHIEF_CC_FREESTYLE_API_URL: "https://freestyle.test", CHIEF_CC_TS_OAUTH: JSON.stringify({ client_id: "test-client", client_secret: "test-client-secret-not-real" }) }
const saved: Record<string, string | undefined> = {}
beforeAll(() => {
  for (const k of [...Object.keys(SETTINGS), "CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA", "CHIEF_CC_OWNERS"]) saved[k] = testEnv[k]
  Object.assign(testEnv, SETTINGS)
})
afterAll(() => {
  for (const [k, v] of Object.entries(saved)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
})
afterEach(() => vi.restoreAllMocks())

interface Started { readonly vm: string; readonly run: string; readonly input: { notes_url: string; token: string; prompt: string; system: string; model: string; net: any } }
/** Freestyle, the Tailscale API and the turn machine at their HTTP boundary; the Worker's own calls go to the real fetch. */
const fakeCloud = (answer: (prompt: string, n: number) => string, during?: (s: Started, n: number) => Promise<void>) => {
  const real = globalThis.fetch
  const made: Array<{ id: string; body: any }> = []
  const deleted: Array<string> = []
  const boots: Array<{ vm: string; stdin: string }> = []
  const started: Array<Started> = []
  // The network apply scripts (chief-brain-cc/net.ts), and every exec in order.
  const nets: Array<{ vm: string; script: string }> = []
  const steps: Array<string> = []
  const keys: Array<string> = []
  // The tags each minted tailnet key asked for.
  const tags: Array<Array<string>> = []
  const other: Array<string> = []
  // Execs outside the turn machine's own steps (the Chief's sandboxes).
  const execs: Array<{ vm: string; command: string; stdin: Uint8Array }> = []
  // Each VM's size (Freestyle's default 4 vCPU / 8 GiB / 32 GB), and every resize asked for.
  const sizes = new Map<string, { cpu: number; memory: number; storage: number }>()
  const resizes: Array<{ vm: string; body: any }> = []
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin === "https://api.tailscale.com") {
      if (url.pathname === "/api/v2/oauth/token") return Response.json({ access_token: "test-ts-access", expires_in: 3600 })
      const key = `tskey-auth-test-${keys.length + 1}`
      keys.push(key)
      expect(req.headers.get("authorization")).toBe("Bearer test-ts-access")
      const asked = (await req.json()) as any
      expect(asked).toMatchObject({ capabilities: { devices: { create: { reusable: false, ephemeral: true, preauthorized: true } } } })
      tags.push(asked.capabilities.devices.create.tags)
      return Response.json({ id: `k${keys.length}`, key })
    }
    if (url.origin !== "https://freestyle.test") {
      if (!url.hostname.endsWith(".test")) return real(input, init)
      other.push(req.url)
      return new Response("not this route", { status: 500 })
    }
    expect(req.headers.get("authorization")).toBe("Bearer test-freestyle-key-not-real")
    if (req.method === "POST" && url.pathname === "/v5/vms") {
      const id = `vm-test${made.length + 1}`
      made.push({ id, body: await req.json() })
      sizes.set(id, { cpu: 4, memory: 8192, storage: 32768 })
      return Response.json({ id })
    }
    const del = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname)
    if (req.method === "DELETE" && del) return deleted.push(del[1]!), Response.json({})
    if (req.method === "GET" && del) {
      const m = made.find((x) => x.id === del[1])
      if (!m || deleted.includes(m.id)) return new Response("no such vm", { status: 404 })
      return Response.json({ id: m.id, state: "running", ipMode: "dualStack", resources: sizes.get(m.id) })
    }
    const rs = /^\/v5\/vms\/([^/]+)\/resize$/.exec(url.pathname)
    if (req.method === "POST" && rs) {
      const vm = rs[1]!
      const body = (await req.json()) as { cpu?: number; memory?: number; storage?: number }
      resizes.push({ vm, body })
      const was = sizes.get(vm)
      if (!was) return Response.json({ code: "NOT_FOUND", message: "no such vm" }, { status: 404 })
      const next = { cpu: body.cpu ?? was.cpu, memory: body.memory ?? was.memory, storage: body.storage ?? was.storage }
      if (next.cpu < was.cpu || next.memory < was.memory || next.storage < was.storage) return Response.json({ code: "BAD_REQUEST", message: "grow only" }, { status: 400 })
      sizes.set(vm, next)
      return Response.json({ id: vm, state: "running", resources: next })
    }
    const ex = /^\/v5\/vms\/([^/]+)\/exec-await$/.exec(url.pathname)
    if (req.method === "POST" && ex) {
      const vm = ex[1]!
      const body = (await req.json()) as { command: string; stdin?: string }
      const stdin = body.stdin ? atob(body.stdin) : ""
      const raw = Uint8Array.from(stdin, (c) => c.charCodeAt(0))
      steps.push(`${vm} ${body.command.split(" ")[0]}`)
      if (body.command.startsWith("/opt/chief-cc/boot.sh ")) return boots.push({ vm, stdin }), Response.json({ statusCode: 0, stdout: "ready\n" })
      if (body.command === "bash -s") return nets.push({ vm, script: stdin }), Response.json({ statusCode: 0, stdout: "net ok\n" })
      const start = /^\/opt\/chief-cc\/start\.sh (run_[0-9]+)$/.exec(body.command)
      if (start) {
        const s: Started = { vm, run: start[1]!, input: JSON.parse(stdin) }
        started.push(s)
        // The turn machine: the stream, then the result, posted to the Worker as run.mjs does.
        const n = started.length
        setTimeout(() => void (during ?? (async () => undefined))(s, n).then(() => machine(s, answer(s.input.prompt, n))), 20)
        return Response.json({ statusCode: 0, stdout: "started\n" })
      }
      execs.push({ vm, command: body.command, stdin: raw })
      if (body.command.includes("resize2fs")) return Response.json({ statusCode: 0, stdout: "/dev/vda 63G 1.2G 62G 2% /\n" })
      return Response.json({ statusCode: 0, stdout: body.command.startsWith("echo ") ? `${body.command.slice(5)}\n` : "" })
    }
    return new Response("unexpected", { status: 500 })
  })
  return { made, deleted, boots, started, nets, steps, keys, tags, other, execs, sizes, resizes }
}
const notes = (s: Started, body: unknown, token = s.input.token) => worker.fetch(s.input.notes_url, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
const machine = async (s: Started, reply: string) => {
  const half = Math.floor(reply.length / 2)
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_start" }, { gen: 0, type: "text_delta", delta: reply.slice(0, half) }] })
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_delta", delta: reply.slice(half) }, { gen: 0, type: "text_done", text: reply }, { gen: 0, type: "done" }] })
  await notes(s, { run: s.run, result: { status: "done", reply, model: s.input.model, usage: { input: 3, output: 7, cache_read: 0, cache_write: 0 }, first_token_ms: 900, total_ms: 1500, last_gen: 0 } })
}

/** `cc`: on the Claude Code route's owner list (and the paid-model list); `paid`: on the paid-model list only. */
const enabledChief = async (sub: string, lists: "cc" | "paid" | false) => {
  const listed = lists !== false
  const token = await sessionToken(sub)
  const ensured = (await op(token, "user.ensure", {})).value
  const user = ensured.id as string
  if (listed) testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA = `${testEnv.CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA ?? ""},${user}`
  if (lists === "cc") testEnv.CHIEF_CC_OWNERS = `${testEnv.CHIEF_CC_OWNERS ?? ""},${user}`
  const chief = (await op(token, "chief.create", { display_name: "Route Chief" }, `chief-${sub}`)).value as { id: string; main_conversation: string }
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  let on = { status: 0, json: {} as any, text: "" }
  for (let i = 0; i < 20 && on.status !== 200; i++) {
    await fireAlarm(userDO)
    on = await http("PUT", `/v1/chiefs/${chief.id}/brain`, token, listed ? { enabled: true, model: "claude-opus-5-5" } : { enabled: true })
  }
  expect(on.status, on.text).toBe(200)
  return { token, user, team: ensured.personal_team as string, chief }
}
const replies = async (token: string, conversation: string, chief: string, n: number) => {
  for (let i = 0; i < 300; i++) {
    const mine = (await history(token, conversation)).filter((m) => m.author === chief)
    if (mine.length >= n) return mine
    await new Promise((r) => setTimeout(r, 50))
  }
  throw new Error(`no ${n} chief replies`)
}
const send = (token: string, conversation: string, key: string, text: string) => op(token, "message.send", { conversation, client_msg_id: key, parts: [{ type: "text", text }] }, key)

describe("Cloud Chief on the Claude Code route", { timeout: 120_000 }, () => {
  it("keeps a teammate-authored turn out of the bypass-permissions VM route", async () => {
    const cloud = fakeCloud(() => "the VM should not run")
    const { token, user, team, chief } = await enabledChief("chief-cc-teammate", "cc")
    const teammate = await sessionToken("chief-cc-teammate-other")
    const teammateUser = (await op(teammate, "user.ensure", {})).value.id as string
    await inDO(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team)), async (instance) => {
      instance.boundEngine.rows.apply([memberUpsert({ user: teammateUser, role: "member", display_name: "Teammate" })])
    })
    const created = await op(token, "conversation.create", {
      title: "Claude Code authorization",
      participants: [
        { id: user, kind: "human", display_name: "Owner" },
        { id: teammateUser, kind: "human", display_name: "Teammate" },
        { id: chief.id, kind: "agent", agent_class: "mux", owner_user: user, display_name: "Route Chief" }
      ]
    })
    expect(created.ok, JSON.stringify(created)).toBe(true)
    const conversation = created.value.conversation.id as string
    const text = "@chief change files on the machine"
    expect((await op(teammate, "message.send", {
      conversation,
      client_msg_id: "cc-teammate-effect",
      parts: [{ type: "text", text, runs: [{ start: 0, length: 6, mention: chief.id }] }]
    }, "cc-teammate-effect")).ok).toBe(true)
    await replies(token, conversation, chief.id, 1)
    expect(cloud.made).toHaveLength(0)
    expect(cloud.keys).toHaveLength(0)
    expect(cloud.started).toHaveLength(0)
  })

  it("runs each turn in its own VM on the tailnet, posts the streamed reply with no Cloud credits, deletes the VM, and gives the next turn the earlier reply", async () => {
    const cloud = fakeCloud((prompt, n) => (n === 1 ? "The launch code word is TANGERINE." : prompt.includes("TANGERINE") ? "You told me before: TANGERINE." : "I do not remember."))
    // No credits granted: this route is not charged to them.
    const { token, chief } = await enabledChief("chief-cc-owner", "cc")
    expect((await send(token, chief.main_conversation, "c1", "pick a code word for the launch")).ok).toBe(true)
    const [first] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(first.parts[0].text).toBe("The launch code word is TANGERINE.")
    expect((await send(token, chief.main_conversation, "c2", "what was the code word?")).ok).toBe(true)
    const [, second] = await replies(token, chief.main_conversation, chief.id, 2)
    expect(second.parts[0].text).toBe("You told me before: TANGERINE.")

    // One VM per turn, from the snapshot, with Freestyle's own timers as the backstop; each deleted by its exact id.
    expect(cloud.made).toHaveLength(2)
    for (const m of cloud.made) expect(m.body).toMatchObject({ snapshotId: "sh-test-chief-cc", idleTimeoutSeconds: 300, automaticRestart: false, firewall: { rules: [{ action: "allow", destination: { public: true } }] } })
    for (const m of cloud.made) expect(m.body.slug).toMatch(/^cmuxnp-test-ccb-[0-9a-f]{12}$/)
    expect(cloud.deleted.sort()).toEqual(["vm-test1", "vm-test2"])
    // Each VM joins with its own one-use key, given on stdin only (never in the command line).
    expect(cloud.boots.map((x) => x.stdin)).toEqual(cloud.keys)
    // The turn input: the person's message, the Chief's system prompt and model; the Worker's own notes URL.
    expect(cloud.started[0]!.input.prompt).toContain("pick a code word for the launch")
    expect(cloud.started[0]!.input.system).toContain("Name: Route Chief")
    expect(cloud.started[0]!.input.model).toBe("claude-opus-5-5")
    expect(cloud.started[0]!.input.notes_url).toBe(`https://api.test/v1/chief-cc/${chief.id}/${chief.main_conversation}/notes`)
    // No call to the Cloud model route.
    expect(cloud.other).toEqual([])

    // The run: done, its reply step, usage and the first-token mark.
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
    expect(runs.map((r) => r.status)).toEqual(["done", "done"])
    const run = (await http("GET", `/v1/chiefs/${chief.id}/runs/${runs[1].id}?conversation=${chief.main_conversation}`, token)).json.value
    expect(run.steps.filter((s: any) => s.kind === "talk").map((s: any) => s.text)).toEqual(["The launch code word is TANGERINE."])
    // Run.timing as a pi run has it: the request at the submit, the first token at the first streamed delta.
    expect(run.run.timing?.request_at).toBeGreaterThan(0)
    expect(run.run.timing?.first_token_at).toBeGreaterThanOrEqual(run.run.timing?.request_at)
    // Neither the tailnet key nor the turn token reaches a reply or a run.
    const all = JSON.stringify([await history(token, chief.main_conversation), runs, run])
    for (const secret of [...cloud.keys, ...cloud.started.map((s) => s.input.token)]) expect(all).not.toContain(secret)
  })

  it("opens the public Internet (IPv4 and IPv6, DNS) to the agent by default: applied after the VM joins, before the turn starts", async () => {
    const cloud = fakeCloud(() => "online")
    const { token, chief } = await enabledChief("chief-cc-net-default", "cc")
    expect((await send(token, chief.main_conversation, "d1", "clone the repo")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect(cloud.steps.slice(0, 3)).toEqual([`${s.vm} /opt/chief-cc/boot.sh`, `${s.vm} bash`, `${s.vm} /opt/chief-cc/start.sh`])
    expect(cloud.nets).toHaveLength(1)
    expect(cloud.nets[0]!.script).toContain(`meta skuid $uid accept`)
    // The turn machine knows its settings (chief-net show) and the Chief is told about the tool.
    expect(s.input.net).toEqual({ internet: true, dns: true, tailnet: true, local: false, allow: [], deny: [] })
    expect(cloud.nets[0]!.script).toContain("ip daddr 100.64.0.0/10 accept")
    expect(cloud.tags).toEqual([["tag:agent-cloud"]])
    expect(s.input.system).toContain("chief-net")
  })

  it("lets the Chief change its own turn machine's network: applied now, kept for its next turns, refused when bad or from another turn", async () => {
    let posted: any = null
    let refused: any = null
    // The turn machine's `chief-net set internet=off` and `chief-net allow github.com`, while its first turn runs.
    const cloud = fakeCloud(
      (_, n) => (n === 1 ? "closing the Internet" : "still closed"),
      async (s, n) => {
        if (n !== 1) return
        const r = await notes(s, { run: s.run, net: { internet: false, allow: ["github.com"] } })
        posted = { status: r.status, body: await r.json().catch(() => null) }
        const bad = await notes(s, { run: s.run, net: { allow: ["github.com; curl evil.example"] } })
        refused = { status: bad.status, body: await bad.json().catch(() => null) }
      }
    )
    const { token, chief } = await enabledChief("chief-cc-net-set", "cc")
    expect((await send(token, chief.main_conversation, "s1", "close your network")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    expect(posted.status).toBe(200)
    expect(posted.body.net).toEqual({ internet: false, dns: true, tailnet: true, local: false, allow: ["github.com"], deny: [] })
    // The script the turn machine applies at once as root.
    expect(posted.body.script).toContain("'github.com'")
    expect(posted.body.script).not.toContain(`meta skuid $uid accept`)
    expect(refused.status).toBe(400)
    expect(refused.body.error).toContain("allow")

    // The next turn's machine starts with the Chief's settings.
    expect((await send(token, chief.main_conversation, "s2", "are you still closed?")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(cloud.started[1]!.input.net).toEqual(posted.body.net)
    expect(cloud.nets[1]!.script).toContain("'github.com'")
    expect(cloud.nets[1]!.script).not.toContain(`meta skuid $uid accept`)
    // A finished turn's token changes nothing.
    const old = cloud.started[0]!
    expect((await notes(old, { run: old.run, net: { internet: true } })).status).toBe(401)
  })

  it("gives the turn machine the Chief's tailnet tag, its tool files and the GitHub token, and keeps them out of replies and runs", async () => {
    const files = { ".config/cloud-chief/mac.token": "mac-token-test-not-real", ".config/agent-hub/token": "hub-token-test-not-real" }
    const extra = { CHIEF_CC_TS_TAG: "tag:lawrence-chief", CHIEF_CC_TURN_FILES: JSON.stringify(files), CHIEF_CC_GITHUB_TOKEN: "github-token-test-not-real" }
    const before = Object.fromEntries(Object.keys(extra).map((k) => [k, testEnv[k]]))
    Object.assign(testEnv, extra)
    try {
      const cloud = fakeCloud(() => "set up")
      const { token, chief } = await enabledChief("chief-cc-route-setup", "cc")
      expect((await send(token, chief.main_conversation, "r1", "check your tools")).ok).toBe(true)
      await replies(token, chief.main_conversation, chief.id, 1)
      const s = cloud.started[0]!
      expect(cloud.tags).toEqual([["tag:lawrence-chief"]])
      expect((s.input as any).files).toEqual(files)
      expect((s.input as any).github_token).toBe("github-token-test-not-real")
      // The Chief is told about its tools on this route.
      for (const word of ["chief-agents", "chief-vm", "mac --", "gh auth status", "100.127.110.65:8790"]) expect(s.input.system).toContain(word)
      const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${chief.main_conversation}`, token)).json.value.runs as Array<any>
      const all = JSON.stringify([await history(token, chief.main_conversation), runs])
      for (const secret of [...Object.values(files), "github-token-test-not-real"]) expect(all).not.toContain(secret)
    } finally {
      for (const [k, v] of Object.entries(before)) v === undefined ? delete testEnv[k] : (testEnv[k] = v)
    }
  })

  it("writes a pasted PNG into the turn machine with the same sha256, before the turn starts, at the path its message line names", async () => {
    const cloud = fakeCloud(() => "I see the screenshot.")
    const { token, chief } = await enabledChief("chief-cc-attachment", "cc")
    const conversation = chief.main_conversation
    // A PNG over one exec's stdin, so the write goes in chunks.
    const png = new Uint8Array(1_700_000)
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    for (let i = 8; i < png.length; i++) png[i] = (i * 31 + 7) & 0xff
    const hash = createHash("sha256").update(png).digest("hex")
    const intent = await http("POST", "/v1/home/attachments/intent", token, { conversation, sha256: hash, byte_count: png.byteLength, mime_type: "image/png", name: "Screenshot 9.47.59.png", width: 2880, height: 1800 })
    expect(intent.json?.ok, intent.text).toBe(true)
    if (intent.json.value.state !== "exists") {
      const put = await worker.fetch(intent.json.value.upload_url, { method: "PUT", body: png, headers: { "content-length": String(png.byteLength) } })
      expect(put.status, await put.clone().text()).toBe(200)
    }
    const part = { type: "attachment", hash, name: "Screenshot 9.47.59.png", mime_type: "image/png", byte_count: png.byteLength, width: 2880, height: 1800 }
    const sent = await op(token, "message.send", { conversation, client_msg_id: "a1", parts: [{ type: "text", text: "what is wrong here?" }, part] }, "a1")
    expect(sent.ok, JSON.stringify(sent)).toBe(true)
    await replies(token, conversation, chief.id, 1)

    const path = `/home/chief/work/.attachments/${hash}.png`
    const s = cloud.started[0]!
    expect(s.input.prompt).toContain(`[attachment: Screenshot 9.47.59.png, image/png 2880x1800 1.6 MB, file ${path}]`)
    // The bytes: the chunks written to the part file, in order, then renamed to the named path.
    const writes = cloud.execs.filter((e) => e.vm === s.vm && /cat >>? \/home\/chief\/work\/\.attachments\//.test(e.command))
    expect(writes.length).toBeGreaterThan(1)
    for (const w of writes) expect(w.stdin.byteLength).toBeLessThanOrEqual(1_000_000)
    const got = new Uint8Array(writes.reduce((n, w) => n + w.stdin.byteLength, 0))
    let at = 0
    for (const w of writes) [got.set(w.stdin, at), (at += w.stdin.byteLength)]
    expect(createHash("sha256").update(got).digest("hex")).toBe(hash)
    expect(cloud.execs.some((e) => e.vm === s.vm && e.command.includes(`mv -f`) && e.command.endsWith(`${path} && echo ok`))).toBe(true)
    // Owned by the agent user, mode 600; written before the turn started.
    expect(cloud.execs.some((e) => e.command.includes("chown chief:chief") && e.command.includes("chmod 600"))).toBe(true)
    const order = cloud.steps.filter((x) => x.startsWith(s.vm))
    expect(order.findIndex((x) => x.endsWith("cat")) >= 0 || order.findIndex((x) => x.endsWith("install")) >= 0).toBe(true)
    expect(order.findIndex((x) => x.endsWith("/opt/chief-cc/start.sh"))).toBeGreaterThan(order.findLastIndex((x) => x.endsWith("chown")))
    // The bytes are in no reply or run.
    const runs = (await http("GET", `/v1/chiefs/${chief.id}/runs?conversation=${conversation}`, token)).json.value.runs as Array<any>
    expect(JSON.stringify(runs)).not.toContain("iVBORw0KGgo")
  })

  it("does not write an attachment of another conversation into the turn machine", async () => {
    const cloud = fakeCloud(() => "ok")
    const { token, chief } = await enabledChief("chief-cc-attachment-other", "cc")
    const foreign = "ab".repeat(32)
    expect((await send(token, chief.main_conversation, "o1", `look at /home/chief/work/.attachments/${foreign}.png`)).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect(cloud.execs.filter((e) => e.vm === s.vm && e.command.includes(".attachments/"))).toHaveLength(0)
    expect(s.input.prompt).toContain(`${foreign}.png (not found in this conversation)`)
  })

  it("lets the Chief keep sandbox VMs of its own across turns: at most two, only its own, through the turn token", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "sandboxes",
      async (s, n) => {
        if (n === 1) {
          seen.a = await call(s, { action: "create" })
          seen.b = await call(s, { action: "create" })
          seen.c = await call(s, { action: "create" })
          seen.exec = await call(s, { action: "exec", id: seen.a.body?.vm?.id, command: "echo hello" })
          seen.foreign = await call(s, { action: "exec", id: s.vm, command: "echo nope" })
          seen.del = await call(s, { action: "delete", id: seen.b.body?.vm?.id })
          seen.bad = await call(s, { action: "format-disk" })
        } else {
          seen.list = await call(s, { action: "list" })
        }
      }
    )
    const { token, chief } = await enabledChief("chief-cc-sandbox", "cc")
    expect((await send(token, chief.main_conversation, "v1", "make two sandboxes")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    expect(seen.a.status).toBe(200)
    expect(seen.b.status).toBe(200)
    expect(seen.c.status).toBe(429)
    const sandbox = cloud.made.find((m) => m.id === seen.a.body.vm.id)!
    expect(sandbox.body.metadata).toMatchObject({ cmux_chief_sandbox: chief.id })
    expect(sandbox.body.ttlSeconds).toBeLessThanOrEqual(12 * 3600)
    expect(seen.exec).toMatchObject({ status: 200, body: { exit: 0, stdout: "hello\n" } })
    expect(cloud.execs.map(({ vm, command }) => ({ vm, command }))).toContainEqual({ vm: seen.a.body.vm.id, command: "echo hello" })
    // The turn machine itself (or any VM it did not make) is not the Chief's sandbox.
    expect(seen.foreign.status).toBe(404)
    expect(cloud.execs.some((e) => e.command === "echo nope")).toBe(false)
    expect(seen.del.status).toBe(200)
    expect(cloud.deleted).toContain(seen.b.body.vm.id)
    expect(seen.bad.status).toBe(400)
    // The next turn still has the sandbox it kept (the turn machines themselves are gone).
    expect((await send(token, chief.main_conversation, "v2", "list them")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 2)
    expect(seen.list.status).toBe(200)
    expect(seen.list.body.vms.map((v: any) => v.id)).toEqual([seen.a.body.vm.id])
    expect(cloud.deleted).not.toContain(seen.a.body.vm.id)
  })

  it("lets the Chief grow its own sandboxes (grow only, capped, then the guest filesystem grows), and size them at create", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: await r.json().catch(() => null) }
    }
    const cloud = fakeCloud(
      () => "resized",
      async (s) => {
        seen.a = await call(s, { action: "create" })
        const id = seen.a.body?.vm?.id
        seen.grow = await call(s, { action: "resize", id, cpu: 8, memory_mb: 16384, disk_gb: 64 })
        seen.shrink = await call(s, { action: "resize", id, cpu: 2 })
        seen.huge = await call(s, { action: "resize", id, cpu: 4096 })
        seen.nothing = await call(s, { action: "resize", id })
        seen.junk = await call(s, { action: "resize", id, memory_mb: "lots" })
        seen.foreign = await call(s, { action: "resize", id: s.vm, cpu: 8 })
        seen.sized = await call(s, { action: "create", cpu: 6, memory_mb: 12288, disk_gb: 48 })
      }
    )
    const { token, chief } = await enabledChief("chief-cc-sandbox-resize", "cc")
    expect((await send(token, chief.main_conversation, "r1", "grow the sandbox")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const id = seen.a.body.vm.id
    expect(seen.grow.status).toBe(200)
    expect(seen.grow.body).toMatchObject({ id, resources: { cpu: 8, memory_mb: 16384, disk_gb: 64 } })
    expect(cloud.resizes).toContainEqual({ vm: id, body: { cpu: 8, memory: 16384, storage: 65536 } })
    expect(cloud.sizes.get(id)).toEqual({ cpu: 8, memory: 16384, storage: 65536 })
    // The disk grew, so the guest's root filesystem is grown too and df shows it.
    expect(cloud.execs.some((e) => e.vm === id && e.command.includes("resize2fs"))).toBe(true)
    expect(seen.grow.body.df).toContain("63G")
    // Grow only, within the cap, a number on some axis, and only the Chief's own sandboxes; none reaches Freestyle.
    expect(seen.shrink.status).toBe(400)
    expect(seen.shrink.body.error).toMatch(/grow/)
    expect(seen.huge.status).toBe(400)
    expect(seen.nothing.status).toBe(400)
    expect(seen.junk.status).toBe(400)
    expect(seen.foreign.status).toBe(404)
    expect(cloud.resizes.filter((r) => r.vm === id)).toHaveLength(1)
    expect(cloud.resizes.some((r) => r.vm !== id && !cloud.made.some((m) => m.id === r.vm && m.body.metadata?.cmux_chief_sandbox))).toBe(false)
    // create takes the same sizes.
    expect(seen.sized.status).toBe(200)
    expect(seen.sized.body.resources).toMatchObject({ cpu: 6, memory_mb: 12288, disk_gb: 48 })
    expect(cloud.sizes.get(seen.sized.body.vm.id)).toEqual({ cpu: 6, memory: 12288, storage: 49152 })
  })

  it("refuses notes without the running turn's token, and after the turn ended", async () => {
    const cloud = fakeCloud(() => "noted")
    const { token, chief } = await enabledChief("chief-cc-notes", "cc")
    expect((await send(token, chief.main_conversation, "n1", "hello")).ok).toBe(true)
    await replies(token, chief.main_conversation, chief.id, 1)
    const s = cloud.started[0]!
    expect((await notes(s, { run: s.run, events: [] }, "not-the-token")).status).toBe(401)
    expect((await notes(s, { run: s.run, events: [] })).status).toBe(401)
    expect((await worker.fetch(s.input.notes_url, { method: "POST", body: "{}" })).status).toBe(401)
  })

  it.each([
    ["off the paid-model list", "chief-cc-other", false],
    ["on the paid-model list but not on the Claude Code route's list", "chief-cc-paid", "paid"]
  ] as const)("leaves an owner %s on the brain they had: no VM", async (_, sub, on) => {
    const cloud = fakeCloud(() => "never")
    const { token, chief } = await enabledChief(sub, on)
    expect((await send(token, chief.main_conversation, "o1", "hi there")).ok).toBe(true)
    const [reply] = await replies(token, chief.main_conversation, chief.id, 1)
    expect(reply.parts[0].text).not.toBe("never")
    expect(cloud.made).toHaveLength(0)
  })
})
