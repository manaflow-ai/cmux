import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { bundleHash, compareSemver } from "../src/app-registry-bundle.ts"
import { handleAppRegistry } from "../src/app-registry-routes.ts"

/**
 * The reviewed app registry (custom-panes-DESIGN.md 6): submit rules, the reviewer gate, approve
 * and reject, and the bundle hash the daemon recomputes. APP_REVIEWERS (vitest.config.ts) lists
 * app_reviewer_1 and app_reviewer_2.
 */
const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string }
const worker = (exports as unknown as { default: Fetcher }).default
const ORIGIN = "https://api.test/v1/apps/registry"
const token = async (sub: string, verified = true) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: verified, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

type Reply = { status: number; body: any; cache: string | null }
const call = async (path: string, init: { method?: string; sub?: string; body?: unknown; verified?: boolean } = {}): Promise<Reply> => {
  const headers: Record<string, string> = { "content-type": "application/json" }
  if (init.sub) headers.authorization = `Bearer ${await token(init.sub, init.verified ?? true)}`
  const res = await worker.fetch(`${ORIGIN}${path}`, { method: init.method ?? "GET", headers, ...(init.body !== undefined ? { body: JSON.stringify(init.body) } : {}) })
  return { status: res.status, body: await res.json(), cache: res.headers.get("cache-control") }
}

const b64 = (s: string | Uint8Array) => {
  const bytes = typeof s === "string" ? new TextEncoder().encode(s) : s
  let bin = ""
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}
const manifestOf = (id: string, version: string) => ({
  manifestVersion: 2,
  id,
  name: "Workspace Board",
  version,
  description: "Every workspace and its terminals.",
  engines: { cmux: "^2.0" },
  runtime: { web: { root: "web/" } },
  implements: { "cmux.pane/1": { web: "web/index.html", title: "Workspace Board" } },
  repository: `https://github.com/${id.split("/")[0]}/board`,
  files: ["web/"]
})
const bundle = (id: string, version: string, extra: Record<string, string> = {}) => {
  const manifest = manifestOf(id, version)
  // Same content, other key order: the file must parse equal, not be byte-equal.
  const file = JSON.stringify(Object.fromEntries(Object.entries(manifest).reverse()))
  return { manifest, files: { "cmux-app.v2.json": b64(file), "web/index.html": b64("<p>hi</p>"), ...extra }, notes: "first cut" }
}
const submit = (sub: string, body: unknown) => call("/submissions", { method: "POST", sub, body })
const decide = (sub: string, id: string, decision: string, reason?: string) => call(`/review/submissions/${id}`, { method: "POST", sub, body: { decision, ...(reason !== undefined ? { reason } : {}) } })

describe("app registry bundle hash", () => {
  it("matches the fixed vector the daemon reimplements", async () => {
    const enc = (s: string) => new TextEncoder().encode(s)
    // sha256("a.txt\0" "2\0" "hi" "b/c.js\0" "1\0" "x"), files in byte order of their paths.
    const vector = "ec32dc4eccc50390124a5707ff1cc349ed1e9f60f29b1844d52de3157ea674a4"
    expect(await bundleHash([{ path: "a.txt", bytes: enc("hi") }, { path: "b/c.js", bytes: enc("x") }])).toBe(vector)
    expect(await bundleHash([{ path: "b/c.js", bytes: enc("x") }, { path: "a.txt", bytes: enc("hi") }])).toBe(vector)
  })
  it("orders semver by precedence", () => {
    expect(compareSemver("1.0.0-alpha", "1.0.0")).toBe(-1)
    expect(compareSemver("1.0.0-alpha.2", "1.0.0-alpha.10")).toBe(-1)
    expect(compareSemver("1.10.0", "1.9.0")).toBe(1)
    expect(compareSemver("1.0.0+a", "1.0.0")).toBe(0)
  })
  it("orders numeric components exactly beyond the JavaScript integer limit", () => {
    const lower = "9007199254740992"
    const higher = "9007199254740993"
    for (const [a, b] of [
      [`1.${higher}.0`, `1.${lower}.0`],
      [`${higher}.0.0`, `${lower}.0.0`],
      [`1.0.${higher}`, `1.0.${lower}`],
      [`1.0.0-${higher}`, `1.0.0-${lower}`],
      ["1.0.0-999999999999999999999999", "1.0.0-100000000000000000000000"],
    ] as const) {
      expect(compareSemver(a, b)).toBe(1)
      expect(compareSemver(b, a)).toBe(-1)
    }
    expect(compareSemver("1.0.0-9007199254740992.a", "1.0.0-9007199254740992.b")).toBe(-1)
    // Treat the leading zeroes the existing prerelease regex accepts as the same numeric value.
    expect(compareSemver("1.0.0-01.a", "1.0.0-1.b")).toBe(-1)
  })

})

describe("app registry submit", () => {
  it("needs a verified person", async () => {
    expect((await call("/me")).status).toBe(401)
    expect((await call("/me", { sub: "app_dev_unverified", verified: false })).status).toBe(403)
    expect((await call("/submissions", { method: "POST", sub: "app_dev_unverified", verified: false, body: bundle("pubu/x", "1.0.0") })).status).toBe(403)
  })

  it("accepts a submission as pending with the bundle hash, claims the publisher and lists it as mine", async () => {
    const body = bundle("alice/board", "0.1.0")
    const r = await submit("app_dev_alice", body)
    expect(r.status).toBe(201)
    expect(r.cache).toBe("no-store")
    const s = r.body.submission
    expect(s).toMatchObject({ app: "alice/board", version: "0.1.0", status: "pending", notes: "first cut", reason: null })
    const files = Object.entries(body.files).map(([path, v]) => ({ path, bytes: Uint8Array.from(atob(v), (c) => c.charCodeAt(0)) }))
    expect(s.sha256).toBe(await bundleHash(files))
    expect(s.size).toBe(files.reduce((n, f) => n + f.bytes.length, 0))
    expect((await call("/me", { sub: "app_dev_alice" })).body).toMatchObject({ reviewer: false, publishers: ["alice"] })
    const mine = (await call("/submissions", { sub: "app_dev_alice" })).body.submissions
    expect(mine.map((m: any) => [m.id, m.status])).toEqual([[s.id, "pending"]])
    expect((await call("/submissions", { sub: "app_dev_bob" })).body.submissions).toEqual([])
  })

  it("refuses reserved publishers and another person's publisher", async () => {
    for (const p of ["cmux", "manaflow-ai", "local"]) expect((await submit("app_dev_carol", bundle(`${p}/thing`, "1.0.0"))).body.error.code).toBe("registry.publisher_reserved")
    const elsewhere = bundle("carol/one", "1.0.0")
    const moved = { ...elsewhere.manifest, repository: "https://github.com/dave/board" }
    const movedBody = { ...elsewhere, manifest: moved, files: { ...elsewhere.files, "cmux-app.v2.json": b64(JSON.stringify(moved)) } }
    expect((await submit("app_dev_carol", movedBody)).body.error.code).toBe("registry.repository")
    expect((await submit("app_dev_carol", bundle("carol/one", "1.0.0"))).status).toBe(201)
    const other = await submit("app_dev_dave", bundle("carol/two", "1.0.0"))
    expect(other).toMatchObject({ status: 403, body: { error: { code: "registry.publisher_taken" } } })
    expect((await submit("app_dev_carol", bundle("carol/two", "1.0.0"))).status).toBe(201)
  })

  it("allows one pending submission per app and only greater versions", async () => {
    const first = await submit("app_dev_erin", bundle("erin/clock", "1.2.0"))
    expect(first.status).toBe(201)
    expect((await submit("app_dev_erin", bundle("erin/clock", "1.3.0"))).body.error.code).toBe("registry.pending_exists")
    expect((await decide("app_reviewer_1", first.body.submission.id, "approve")).status).toBe(200)
    for (const v of ["1.2.0", "1.1.9", "1.2.0-rc.1", "1.2.0+build"]) expect((await submit("app_dev_erin", bundle("erin/clock", v))).body.error.code).toBe("registry.version_order")
    const rejected = await submit("app_dev_erin", bundle("erin/clock", "1.3.0"))
    expect(rejected.status).toBe(201)
    expect((await decide("app_reviewer_1", rejected.body.submission.id, "reject", "the pane reads too much")).status).toBe(200)
    // A rejected version may be submitted again.
    expect((await submit("app_dev_erin", bundle("erin/clock", "1.3.0"))).status).toBe(201)
  })

  it("accepts and publishes a version beyond JavaScript's integer precision", async () => {
    const app = "precision/pane"
    const user = "app_dev_precision"
    const lower = "1.9007199254740992.0"
    const higher = "1.9007199254740993.0"
    const first = await submit(user, bundle(app, lower))
    expect(first.status).toBe(201)
    expect((await decide("app_reviewer_1", first.body.submission.id, "approve")).status).toBe(200)
    const next = await submit(user, bundle(app, higher))
    expect(next.status).toBe(201)
    expect((await decide("app_reviewer_2", next.body.submission.id, "approve")).status).toBe(200)
    const versions = (await call("/apps/precision/pane")).body
    expect(versions.latest).toBe(higher)
    expect(versions.versions.map((v: any) => v.version)).toEqual([higher, lower])
    const listing = (await call("/listings?query=precision")).body.listings
    expect(listing).toEqual([expect.objectContaining({ app, version: higher })])
  })

  it("enforces the file count, the decoded size and safe paths", async () => {
    const many: Record<string, string> = {}
    for (let i = 0; i < 200; i++) many[`web/f${i}.js`] = b64("x")
    expect((await submit("app_dev_frank", bundle("frank/many", "1.0.0", many))).body.error.code).toBe("registry.too_many_files")
    const big = b64(new Uint8Array(2 * 1024 * 1024))
    expect((await submit("app_dev_frank", bundle("frank/big", "1.0.0", { "web/big.bin": big }))).body.error.code).toBe("registry.too_large")
    for (const p of ["../evil.js", "/abs.js", "web/../x.js", "web//x.js", "web\\x.js", "web/./x.js", "web/x y.js"]) {
      const r = await submit("app_dev_frank", bundle("frank/paths", "1.0.0", { [p]: b64("x") }))
      expect([r.status, r.body.error.code]).toEqual([400, "registry.path"])
    }
    expect((await submit("app_dev_frank", bundle("frank/paths", "1.0.0", { "WEB/INDEX.HTML": b64("x") }))).body.error.code).toBe("registry.path")
    expect((await submit("app_dev_frank", bundle("frank/paths", "1.0.0", { web: b64("x") }))).body.error.code).toBe("registry.path")
    expect((await submit("app_dev_frank", bundle("frank/paths", "1.0.0", { "web/a.js": "not base64!" }))).body.error.code).toBe("registry.files")
  })

  it("needs the manifest file among the files, equal to manifest", async () => {
    const b = bundle("gina/pane", "1.0.0")
    const { "cmux-app.v2.json": _drop, ...rest } = b.files
    expect((await submit("app_dev_gina", { ...b, files: rest })).body.error.code).toBe("registry.manifest_file")
    const mismatch = { ...b, files: { ...b.files, "cmux-app.v2.json": b64(JSON.stringify(manifestOf("gina/pane", "1.0.1"))) } }
    expect((await submit("app_dev_gina", mismatch)).body.error.code).toBe("registry.manifest_mismatch")
    // Both names: the daemon would install the other one.
    const both = { ...b, files: { ...b.files, "cmux-app.json": b64(JSON.stringify(b.manifest)) } }
    expect((await submit("app_dev_gina", both)).body.error.code).toBe("registry.manifest_file")
    // A second manifest in another case would be the one a case-insensitive disk installs.
    const cased = { ...b, files: { ...b.files, "Cmux-App.json": b64(JSON.stringify(b.manifest)) } }
    expect((await submit("app_dev_gina", cased)).body.error.code).toBe("registry.manifest_file")
    // A pane policy that could name a URL to send to is refused.
    const leaky = { ...manifestOf("gina/pane", "1.0.0"), runtime: { web: { root: "web", csp: "img-src 'self'; report-uri https://evil.example/r" } } }
    const leakyBody = { ...b, manifest: leaky, files: { ...b.files, "cmux-app.v2.json": b64(JSON.stringify(leaky)) } }
    expect((await submit("app_dev_gina", leakyBody)).body.error.code).toBe("registry.csp")
    // The v1 file name also counts when it is the only manifest file.
    expect((await submit("app_dev_gina", { ...b, files: { ...rest, "cmux-app.json": b64(JSON.stringify(b.manifest)) } })).status).toBe(201)
  })
})

describe("app registry review", () => {
  it("answers 404 without APP_REVIEWERS and 403 for a person who is not a reviewer", async () => {
    const req = new Request(`${ORIGIN}/review/queue`, { headers: { authorization: `Bearer ${await token("app_reviewer_1")}` } })
    expect((await handleAppRegistry(req, { ...env, APP_REVIEWERS: undefined } as any)).status).toBe(404)
    expect((await handleAppRegistry(req.clone(), { ...env, APP_REVIEWERS: " , " } as any)).status).toBe(404)
    expect((await call("/review/queue", { sub: "app_dev_alice" })).status).toBe(403)
    expect((await call("/review/queue")).status).toBe(401)
    expect((await call("/me", { sub: "app_reviewer_1" })).body.reviewer).toBe(true)
  })

  it("never lets a reviewer decide their own submission", async () => {
    const own = await submit("app_reviewer_1", bundle("rev/own", "1.0.0"))
    expect(own.status).toBe(201)
    expect(await decide("app_reviewer_1", own.body.submission.id, "approve")).toMatchObject({ status: 403, body: { error: { code: "registry.own_submission" } } })
    expect((await decide("app_reviewer_2", own.body.submission.id, "approve")).body.submission.status).toBe("approved")
    expect((await decide("app_reviewer_2", own.body.submission.id, "reject", "changed my mind here")).body.error.code).toBe("registry.decided")
  })

  it("serves a file named like an object prototype key as a file", async () => {
    const body = bundle("quinn/proto", "1.0.0", { ["__proto__"]: b64("p"), "web/constructor": b64("c") })
    const s = (await submit("app_dev_quinn", body)).body.submission
    expect((await decide("app_reviewer_1", s.id, "approve")).status).toBe(200)
    const got = await call(`/apps/quinn/proto/versions/1.0.0/bundle`)
    expect(Object.keys(got.body.files).sort()).toEqual(Object.keys(body.files).sort())
    expect(got.body.files["__proto__"]).toBe(b64("p"))
  })

  it("shows the queue and files, and after approval lists the app and serves the same bundle", async () => {
    const body = bundle("hank/notes", "2.0.0", { "web/app.js": b64("console.log(1)") })
    const s = (await submit("app_dev_hank", body)).body.submission
    const missing = await call(`/apps/hank/notes/versions/2.0.0/bundle`)
    expect(missing.status).toBe(404)
    expect((await call("/apps/hank/notes")).status).toBe(404)
    const queued = (await call("/review/queue", { sub: "app_reviewer_1" })).body.submissions.find((q: any) => q.id === s.id)
    expect(queued).toMatchObject({ submitter: s.submitter, notes: "first cut", manifest: body.manifest })
    expect(queued.files.map((f: any) => f.path)).toEqual(["cmux-app.v2.json", "web/app.js", "web/index.html"])
    expect((await call(`/review/submissions/${s.id}/files?path=web/app.js`, { sub: "app_reviewer_1" })).body).toEqual({ path: "web/app.js", base64: b64("console.log(1)") })
    expect((await call(`/review/submissions/${s.id}/files?path=nope.js`, { sub: "app_reviewer_1" })).status).toBe(404)

    const approved = await decide("app_reviewer_2", s.id, "approve")
    expect(approved.body.submission).toMatchObject({ status: "approved", decided_by: expect.stringMatching(/^user_/) })
    const listing = (await call("/listings?query=hank")).body.listings
    expect(listing).toEqual([expect.objectContaining({ app: "hank/notes", publisher: "hank", name: "Workspace Board", version: "2.0.0", sha256: s.sha256, size: s.size })])
    expect((await call("/listings?query=no-such-app-anywhere")).body.listings).toEqual([])
    const app = await call("/apps/hank/notes")
    expect(app.body).toMatchObject({ app: "hank/notes", latest: "2.0.0", versions: [{ version: "2.0.0", sha256: s.sha256 }] })
    const got = await call(`/apps/hank/notes/versions/2.0.0/bundle`)
    expect(got.status).toBe(200)
    expect(got.body.files).toEqual(body.files)
    const files = Object.entries(got.body.files as Record<string, string>).map(([path, v]) => ({ path, bytes: Uint8Array.from(atob(v), (c) => c.charCodeAt(0)) }))
    expect(await bundleHash(files)).toBe(s.sha256)
    expect(got.body.sha256).toBe(s.sha256)

    // A newer pending version leaves the listing on the approved one; its bundle is 404 until approved.
    const next = (await submit("app_dev_hank", bundle("hank/notes", "2.1.0"))).body.submission
    expect((await call("/listings?query=hank")).body.listings[0].version).toBe("2.0.0")
    expect((await call(`/apps/hank/notes/versions/2.1.0/bundle`)).status).toBe(404)
    await decide("app_reviewer_1", next.id, "approve")
    expect((await call("/listings?query=hank")).body.listings[0].version).toBe("2.1.0")
    expect((await call("/apps/hank/notes")).body.versions.map((v: any) => v.version)).toEqual(["2.1.0", "2.0.0"])
  })

  it("needs a reason to reject and shows it to the submitter", async () => {
    const s = (await submit("app_dev_ivy", bundle("ivy/tool", "1.0.0"))).body.submission
    expect((await decide("app_reviewer_1", s.id, "reject")).body.error.code).toBe("registry.reason")
    expect((await decide("app_reviewer_1", s.id, "reject", "short")).body.error.code).toBe("registry.reason")
    expect((await decide("app_reviewer_1", s.id, "reject", "x".repeat(501))).body.error.code).toBe("registry.reason")
    expect((await decide("app_reviewer_1", s.id, "maybe")).body.error.code).toBe("registry.decision")
    expect((await decide("app_reviewer_1", s.id, "reject", "It asks for terminal:execute without need.")).body.submission.status).toBe("rejected")
    const mine = (await call("/submissions", { sub: "app_dev_ivy" })).body.submissions
    expect(mine[0]).toMatchObject({ id: s.id, status: "rejected", reason: "It asks for terminal:execute without need." })
    expect((await call(`/apps/ivy/tool/versions/1.0.0/bundle`)).status).toBe(404)
    expect((await call("/listings?query=ivy")).body.listings).toEqual([])
  })
})
