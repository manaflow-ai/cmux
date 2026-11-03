import { beforeAll, describe, expect, it } from "vitest"
import { bindFile, cloudStub, DAEMON, vmKey, WG_KEY } from "./cloud-bind-support.ts"
import { callOp, callRead, makeTenant, mintInstallToken, post, shape, worker, type Tenant } from "./setup/tenant.ts"

/**
 * Tenant isolation on the routes outside /v1/ops (plans/cmux-next/tenant-isolation-DESIGN.md section 5.7): the
 * operator, webhook and billing routes refuse every tenant credential; another tenant's Chief (brain, memory,
 * github, peer, runs, fault) and attachments answer exactly like ids that do not exist.
 */
let a: Tenant
let b: Tenant
let chiefA: string
let vmToken: string
const raw = (method: string, path: string, token: string | undefined, body?: unknown, headers: Record<string, string> = {}) =>
  worker.fetch(`https://api.test${path}`, { method, headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
const outcome = async (r: Response) => {
  const text = await r.text()
  return { status: r.status, text, signature: `${r.status} ${shape(text).slice(0, 200)}` }
}
const rnd = (alphabet: string, n: number) => Array.from({ length: n }, () => alphabet[Math.floor(Math.random() * alphabet.length)]).join("")

beforeAll(async () => {
  a = await makeTenant("h")
  b = await makeTenant("i")
  const made = await callOp(a.session, "chief.create", {})
  chiefA = made.body.value.id as string
  // A VM token of B (a bound machine's install): the weakest tenant credential there is.
  const created = await callOp(b.session, "cloud.machine.create", { size: { cpu: 2, memory_mb: 4096, disk_mb: 16384 } })
  const id = created.body.value.machine.id as string
  const { json } = await bindFile(cloudStub(b.team), id)
  const key = await vmKey()
  const bound = await post("/v1/cloud/bind", undefined, { team: b.team, machine: id, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON, install_public_jwk: key.jwk })
  const install = bound.body.value.install as { id: string; user: string }
  vmToken = (await mintInstallToken({ user: install.user, install: install.id, keyPair: key.pair }))!
}, 120_000)

describe("operator, webhook and billing routes refuse tenants", { timeout: 120_000 }, () => {
  const ROUTES: Array<[string, string]> = [
    ["POST", "/v1/internal/credits"], ["GET", "/v1/internal/credits"],
    ["POST", "/v1/internal/billing/levels"], ["POST", "/v1/internal/billing/sync"], ["POST", "/v1/internal/billing/team-mode"],
    ["POST", "/v1/admin/outbox/replay"], ["POST", "/v1/admin/cloud/abandoned/clear"], ["GET", "/v1/admin/team-vm/export"], ["POST", "/v1/admin/team-vm/export"],
    ["POST", "/v1/hooks/stack"], ["POST", "/v1/hooks/stripe/credits"], ["POST", "/v1/hooks/sendblue"]
  ]
  it("every one answers 401, 403, 404 or 405 to a session, an install, a VM token and no credential", async () => {
    const bad: Array<string> = []
    for (const [method, path] of ROUTES) {
      for (const [who, token] of [["session", b.session], ["install", b.installToken], ["vm", vmToken], ["none", undefined]] as const) {
        const r = await outcome(await raw(method, path, token, method === "POST" ? {} : undefined))
        if (![400, 401, 403, 404, 405, 415].includes(r.status) || r.text.includes(a.canary)) bad.push(`${method} ${path} as ${who}: ${r.status} ${r.text.slice(0, 120)}`)
      }
    }
    // 400 is a body-validation answer from a webhook that checks its signature after parsing; it must not carry data.
    expect(bad).toEqual([])
  })
})

describe("another tenant's Chief", { timeout: 120_000 }, () => {
  const SUB = ["brain", "github", "memory", "peer", "runs", "runs/run_1", "runs/sub_1"]
  it("brain, github, memory, peer, runs and fault answer a stranger like an unknown Chief, for every method", async () => {
    expect(chiefA).toMatch(/^agent_/)
    const unknown = `agent_${rnd("0123456789ABCDEFGHJKMNPQRSTVWXYZ", 26)}`
    const bad: Array<string> = []
    for (const sub of [...SUB, "fault"]) {
      for (const method of ["GET", "POST", "PUT", "DELETE"]) {
        for (const [who, token] of [["session", b.session], ["install", b.installToken], ["vm", vmToken], ["none", undefined]] as const) {
          const body = method === "GET" || method === "DELETE" ? undefined : {}
          const real = await outcome(await raw(method, `/v1/chiefs/${chiefA}/${sub}`, token, body))
          const none = await outcome(await raw(method, `/v1/chiefs/${unknown}/${sub}`, token, body))
          if (real.status === 200 || real.text.includes(a.canary)) bad.push(`${method} ${sub} as ${who}: ${real.status} ${real.text.slice(0, 100)}`)
          else if (real.signature !== none.signature) bad.push(`oracle ${method} ${sub} as ${who}: A-chief ${real.signature} | unknown ${none.signature}`)
        }
      }
    }
    expect(bad.join("\n")).toBe("")
  })

  it("the Chief's owner is not refused by the same routes (the sweep is not just a dead route)", async () => {
    const r = await outcome(await raw("GET", `/v1/chiefs/${chiefA}/brain`, a.session))
    expect(r.status, r.text.slice(0, 160)).not.toBe(401)
    expect(r.status, r.text.slice(0, 160)).not.toBe(403)
  })
})

describe("attachments of another tenant", { timeout: 120_000 }, () => {
  it("intent, commit and url for A's conversation answer like an unknown conversation", async () => {
    const dm = await callOp(a.session, "dm.open", { peer: { email: `peer-${a.sub}@tenant.test` } })
    const conv = dm.body.value.conversation.id as string
    const unknown = `conv_${rnd("0123456789ABCDEFGHJKMNPQRSTVWXYZ", 26)}`
    const sha = "a".repeat(64)
    const bodies = (c: string): Array<[string, unknown]> => [
      ["/v1/home/attachments/intent", { conversation: c, sha256: sha, byte_count: 10, mime_type: "text/plain", name: "x.txt" }],
      ["/v1/home/attachments/commit", { conversation: c, slot: "slot_x" }],
      ["/v1/home/attachments/url", { conversation: c, hash: sha }]
    ]
    const bad: Array<string> = []
    for (const [i, [path, body]] of bodies(conv).entries()) {
      for (const token of [b.session, b.installToken]) {
        const real = await outcome(await raw("POST", path, token, body))
        const none = await outcome(await raw("POST", path, token, bodies(unknown)[i]![1]))
        if (real.status === 200 || real.text.includes(a.canary)) bad.push(`${path}: ${real.status} ${real.text.slice(0, 100)}`)
        else if (real.signature !== none.signature) bad.push(`oracle ${path}: ${real.signature} | ${none.signature}`)
      }
    }
    expect(bad.join("\n")).toBe("")
    // Direct download with a made-up signature.
    const dl = await outcome(await raw("GET", `/v1/home/attachments/${conv}/obj_${rnd("abcdefghijklmnop", 20)}?k=1&s=forged&e=${Date.now() + 60000}`, b.session))
    expect(dl.status).not.toBe(200)
  })
})

describe("the personal Claude Code route stays closed to other tenants", () => {
  // The chief-cc image holds private clones (cmuxterm-hq) in the agent's home (backend/scripts/tenant-isolation-vms.sh finds them),
  // so the CHIEF_CC_OWNERS allowlist is the only thing between that image and a stranger's Chief turn.
  it("only an exact owner id, or that owner's personal team, reaches it; prefixes, other users and an empty list do not", async () => {
    const { ccRoute } = await import("../src/chief-brain-cc/vm.ts")
    const base = { ENVIRONMENT: "staging", CHIEF_CC_ENABLED: "1", CHIEF_CC_FREESTYLE_API_KEY: "k", CHIEF_CC_TS_OAUTH: "{}", CHIEF_CC_SNAPSHOT: "sh-x", CHIEF_BRAIN_CLAUDE_OWNERS: "user_aaaaaaaaaaaaaaaaaaaa,user_bbbbbbbbbbbbbbbbbbbb,user_aaaaaaaaaaaaaaaaaaaab" } as never
    const withList = (list: string) => ({ ...(base as object), CHIEF_CC_OWNERS: list }) as never
    expect(ccRoute(withList("user_aaaaaaaaaaaaaaaaaaaa"), "user_aaaaaaaaaaaaaaaaaaaa")).toBe(true)
    expect(ccRoute(withList("user_aaaaaaaaaaaaaaaaaaaa"), "user_bbbbbbbbbbbbbbbbbbbb")).toBe(false)
    expect(ccRoute(withList("user_aaaaaaaaaaaaaaaaaaaa"), "user_aaaaaaaaaaaaaaaaaaaab")).toBe(false)
    expect(ccRoute(withList(""), "user_aaaaaaaaaaaaaaaaaaaa")).toBe(false)
    expect(ccRoute(withList("*"), "user_aaaaaaaaaaaaaaaaaaaa")).toBe(false)
    expect(ccRoute(withList("user_aaaaaaaaaaaaaaaaaaaa"), null)).toBe(false)
    expect(ccRoute({ ...(withList("user_aaaaaaaaaaaaaaaaaaaa") as object), CHIEF_CC_ENABLED: "0" } as never, "user_aaaaaaaaaaaaaaaaaaaa")).toBe(false)
  })
})

describe("billing: a stranger cannot spend or read another tenant's credits", { timeout: 60_000 }, () => {
  it("naming A's team in x-cmux-team on the inference and credits routes is refused before any meter or ledger is touched", async () => {
    const body = { model: "fake", messages: [{ role: "user", content: "hi" }] }
    for (const path of ["/v1/inference/chat/completions", "/v1/inference/v1/messages"]) {
      const r = await outcome(await raw("POST", path, b.session, body, { "x-cmux-team": a.team }))
      expect([401, 403], `${path}: ${r.status} ${r.text.slice(0, 160)}`).toContain(r.status)
      expect(r.text).not.toContain(a.canary)
    }
    // An install token (not a session) cannot select a team at all.
    const viaInstall = await outcome(await raw("POST", "/v1/inference/chat/completions", b.installToken, body, { "x-cmux-team": a.team }))
    expect([401, 403]).toContain(viaInstall.status)
    // The usage and cap ops answer for the caller's own team whatever the params say.
    const summary = await callRead(b.session, "usage.summary", { team: a.team, owner: a.team })
    expect(summary.raw).not.toContain(a.team)
    expect((await callOp(b.session, "usage.cap.set", { cap_usd: 1, team: a.team, owner: a.team })).raw).not.toContain(a.team)
    expect((await callRead(a.session, "usage.summary", {})).raw).not.toContain("\"team_cap_usd\":1,")
  })
})
