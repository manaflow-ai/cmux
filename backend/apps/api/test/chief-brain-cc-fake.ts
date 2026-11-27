import { exports } from "cloudflare:workers"
import { expect, vi } from "vitest"

const worker = (exports as unknown as { default: Fetcher }).default

/**
 * The Freestyle and Tailscale API fakes of chief-brain-cc.test.ts, at their HTTP boundary (moved here
 * unchanged so that test file stays under the backend's 1000-line / 64 KB limit, scripts/check-file-size.ts).
 */
export interface Started { readonly vm: string; readonly run: string; readonly input: { notes_url: string; token: string; prompt: string; system: string; model: string; net: any; max_ms: number } }
/** What the fake turn machine does: post this reply as chief-turn-runner does, or play the machine itself. */
export type Answer = string | ((s: Started) => Promise<void>)
/**
 * Freestyle, the Tailscale API and the turn machine at their HTTP boundary; the Worker's own calls go to the real fetch.
 * `bootFails(n)`: the n-th VM's boot fails (it never joins the network).
 */
export const fakeCloud = (answer: (prompt: string, n: number) => Answer, during?: (s: Started, n: number) => Promise<void>, bootFails?: (n: number) => boolean, latency: { create?: number; key?: number; boot?: number; net?: number } = {}) => {
  // Start and end of the turn's setup calls, in order (a test asserts which ones overlap).
  const events: Array<{ name: string; at: number }> = []
  const wait = (ms: number | undefined) => (ms ? new Promise((r) => setTimeout(r, ms)) : undefined)
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
  // Client sessions (sandbox-access.ts): identities with VM grants and tokens; every sandbox exec's credential.
  const identities = new Map<string, { grants: Map<string, Array<string> | null> }>()
  const tokens = new Map<string, { id: string; identity: string; revoked: boolean; expires: number }>()
  const execAuth: Array<{ vm: string; by: string; user: string | null }> = []
  const states = new Map<string, string>()
  const patches: Array<{ vm: string; body: any }> = []
  // Guest files per VM (fs routes), uploads, snapshots and every lifecycle call.
  const files = new Map<string, Map<string, Uint8Array>>()
  const uploads = new Map<string, { vm: string; path: string; size: number; got: Array<number> }>()
  const snapshots = new Map<string, { source: string; body: any; deleted?: boolean }>()
  const lifecycle: Array<string> = []
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init)
    const url = new URL(req.url)
    if (url.origin === "https://api.tailscale.com") {
      if (url.pathname === "/api/v2/oauth/token") return Response.json({ access_token: "test-ts-access", expires_in: 3600 })
      events.push({ name: "key:start", at: Date.now() })
      await wait(latency.key)
      events.push({ name: "key:end", at: Date.now() })
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
    const idToken = req.headers.get("x-freestyle-identity-access-token")
    // An identity token reaches only a granted VM's exec route; everything else needs the team key.
    if (idToken !== null) {
      expect(req.headers.get("authorization")).toBeNull()
      const ex = /^\/v5\/vms\/([^/]+)\/exec-await$/.exec(url.pathname)
      if (!ex || req.method !== "POST") return Response.json({ code: "FORBIDDEN", message: "identity tokens reach exec and pty only" }, { status: 403 })
      const t = tokens.get(idToken)
      if (!t || t.revoked || t.expires < Date.now() || !identities.has(t.identity)) return Response.json({ code: "UNAUTHORIZED", message: "invalid identity access token" }, { status: 401 })
      const body = (await req.json()) as { command: string; linuxUser?: string; env?: Record<string, string>; stdin?: string }
      const allowed = identities.get(t.identity)!.grants.get(ex[1]!)
      if (allowed === undefined || (allowed !== null && !allowed.includes(body.linuxUser ?? ""))) return Response.json({ code: "FORBIDDEN", message: "no access to this VM as that user" }, { status: 403 })
      execAuth.push({ vm: ex[1]!, by: `identity:${t.identity}`, user: body.linuxUser ?? null })
      execs.push({ vm: ex[1]!, command: body.command, stdin: body.stdin ? Uint8Array.from(atob(body.stdin), (c) => c.charCodeAt(0)) : new Uint8Array() })
      if (/(^|[;( ])poweroff/.test(body.command)) states.set(ex[1]!, "stopped")
      if (body.command.includes("resize2fs")) return Response.json({ statusCode: 0, stdout: "/dev/vda 63G 1.2G 62G 2% /\n", stderr: "" })
      if (body.command === "printenv GREETING; cat") return Response.json({ statusCode: 0, stdout: `${body.env?.GREETING ?? ""}\n${body.stdin ? atob(body.stdin) : ""}`, stderr: "" })
      if (body.command === "whoami") return Response.json({ statusCode: 0, stdout: `${body.linuxUser}\n`, stderr: "" })
      if (body.command.startsWith("nproc; awk")) {
        const z = sizes.get(ex[1]!)!
        return Response.json({ statusCode: 0, stdout: `${z.cpu}\n${z.memory - 190}\n/dev/vda ${Math.round(z.storage / 1024) - 1}G 1.2G 62G 2% /\n`, stderr: "" })
      }
      return Response.json({ statusCode: 0, stdout: body.command.startsWith("echo ") ? `${body.command.slice(5)}\n` : "", stderr: "" })
    }
    expect(req.headers.get("authorization")).toBe("Bearer test-freestyle-key-not-real")
    const idn = /^\/v5\/identities(?:\/([^/]+)(?:\/(permissions\/vm|tokens)(?:\/([^/]+))?)?)?$/.exec(url.pathname)
    if (idn) {
      const [, who, kind, sub] = idn
      if (!who && req.method === "POST") {
        const id = `idn-test${identities.size + 1}`
        identities.set(id, { grants: new Map() })
        return Response.json({ id, managed: false })
      }
      const it = who ? identities.get(who) : undefined
      if (!it) return Response.json({ code: "NOT_FOUND", message: "no such identity" }, { status: 404 })
      if (!kind && req.method === "GET") return Response.json({ id: who, managed: false })
      if (!kind && req.method === "DELETE") {
        identities.delete(who!)
        for (const t of tokens.values()) if (t.identity === who) t.revoked = true
        return Response.json({})
      }
      if (kind === "permissions/vm" && req.method === "POST") {
        const body = (await req.json()) as { vmId: string; allowedLinuxUsers?: Array<string> | null }
        it.grants.set(body.vmId, body.allowedLinuxUsers ?? null)
        return Response.json({ id: `vmp-${body.vmId}`, identityId: who, vmId: body.vmId, allowedLinuxUsers: body.allowedLinuxUsers ?? null })
      }
      if (kind === "permissions/vm" && req.method === "DELETE" && sub) return it.grants.delete(sub), Response.json({})
      if (kind === "tokens" && req.method === "POST") {
        const body = (await req.json()) as { expiresAt?: string }
        const id = `tok-test${tokens.size + 1}`
        const token = `idtok-secret-${tokens.size + 1}-not-real`
        tokens.set(token, { id, identity: who!, revoked: false, expires: body.expiresAt ? Date.parse(body.expiresAt) : Infinity })
        return Response.json({ id, token, expiresAt: body.expiresAt ?? null })
      }
      if (kind === "tokens" && req.method === "DELETE" && sub) {
        for (const t of tokens.values()) if (t.id === sub) t.revoked = true
        return Response.json({})
      }
      return new Response("unexpected", { status: 500 })
    }
    const life = /^\/v5\/vms\/([^/]+)\/(pause|start)$/.exec(url.pathname)
    if (req.method === "POST" && life) return lifecycle.push(`${life[1]} ${life[2]}`), states.set(life[1]!, life[2] === "pause" ? "paused" : "running"), Response.json({ id: life[1], state: states.get(life[1]!) })
    const fsm = /^\/v5\/vms\/([^/]+)\/fs\/([a-z]+)(?:\/([^/]+)(\/commit)?)?$/.exec(url.pathname)
    if (fsm) {
      const [, vm, op, up, commit] = fsm
      const fsOf = files.get(vm!) ?? new Map<string, Uint8Array>()
      files.set(vm!, fsOf)
      const path = url.searchParams.get("path") ?? ""
      if (op === "write" && req.method === "PUT") {
        const body = (await req.json()) as { path: string; content: string; encoding?: string }
        fsOf.set(body.path, body.encoding === "base64" ? Uint8Array.from(atob(body.content), (c) => c.charCodeAt(0)) : new TextEncoder().encode(body.content))
        return new Response(null, { status: 204 })
      }
      if (op === "read") {
        const f = fsOf.get(path)
        if (!f) return Response.json({ code: "NOT_FOUND", message: "no such file" }, { status: 404 })
        const m = /^bytes=(\d+)-(\d+)$/.exec(req.headers.get("range") ?? "")
        if (!m) return new Response(f)
        const a = Number(m[1])
        if (a >= f.length) return new Response(null, { status: 416 })
        const part = f.subarray(a, Math.min(f.length, Number(m[2]) + 1))
        return new Response(part, { status: 206, headers: { "content-range": `bytes ${a}-${a + part.length - 1}/${f.length}` } })
      }
      if (op === "dir") return Response.json({ entries: [...fsOf.keys()].filter((k) => k.startsWith(`${path.replace(/\/$/, "")}/`)).map((k) => ({ name: k.slice(path.replace(/\/$/, "").length + 1).split("/")[0], kind: "file" })) })
      if (op === "stat") return fsOf.has(path) ? Response.json({ size: fsOf.get(path)!.length, isFile: true, isDirectory: false, isSymlink: false, permissions: "0644", owner: "root", group: "root", modified: "2026-10-21T00:00:00Z" }) : Response.json({ code: "NOT_FOUND", message: "no such path" }, { status: 404 })
      if (op === "exists") return Response.json({ exists: fsOf.has(path) })
      if (op === "mkdir") return new Response(null, { status: 204 })
      if (op === "remove") return fsOf.delete(path), new Response(null, { status: 204 })
      if (op === "uploads" && req.method === "POST" && !up) {
        const body = (await req.json()) as { path: string; size: number }
        const id = `up-${uploads.size + 1}`
        uploads.set(id, { vm: vm!, path: body.path, size: body.size, got: [] })
        return Response.json({ uploadId: id, receivedBytes: 0, size: body.size })
      }
      const u = up ? uploads.get(up) : undefined
      if (op === "uploads" && u && req.method === "PUT") {
        expect(req.headers.get("content-type")).toBe("application/octet-stream")
        if (Number(url.searchParams.get("offset")) !== u.got.length) return Response.json({ code: "CONFLICT", message: "offset" }, { status: 409 })
        for (const x of new Uint8Array(await req.arrayBuffer())) u.got.push(x)
        return Response.json({ uploadId: up, receivedBytes: u.got.length, size: u.size })
      }
      if (op === "uploads" && u && commit && req.method === "POST") return fsOf.set(u.path, Uint8Array.from(u.got)), uploads.delete(up!), new Response(null, { status: 204 })
      return new Response("unexpected fs", { status: 500 })
    }
    const snapOf = /^\/v5\/vms\/([^/]+)\/snapshot$/.exec(url.pathname)
    if (snapOf && req.method === "POST") {
      const id = `sn-test${snapshots.size + 1}`
      snapshots.set(id, { source: snapOf[1]!, body: await req.json() })
      return Response.json({ snapshotId: id, snapshot: { id }, sourceVmId: snapOf[1] })
    }
    const sn = /^\/v5\/snapshots\/([^/]+)$/.exec(url.pathname)
    if (sn) {
      const it = snapshots.get(sn[1]!)
      if (!it || it.deleted) return Response.json({ code: "NOT_FOUND", message: "no such snapshot" }, { status: 404 })
      if (req.method === "DELETE") return (it.deleted = true), Response.json({})
      if (req.method === "PATCH") it.body = { ...it.body, ...((await req.json()) as object) }
      return Response.json({ id: sn[1], displayName: it.body.displayName ?? null, ttlSeconds: it.body.ttlSeconds ?? null })
    }
    if (req.method === "POST" && url.pathname === "/v5/vms") {
      events.push({ name: "create:start", at: Date.now() })
      const body = await req.json()
      await wait(latency.create)
      events.push({ name: "create:end", at: Date.now() })
      const id = `vm-test${made.length + 1}`
      made.push({ id, body })
      // A VM starts at its snapshot's size (the small Ubuntu base is 2 vCPU / 4 GiB / 16 GB).
      sizes.set(id, made[made.length - 1]!.body.snapshotId === "freestyle/ubuntu-sm" ? { cpu: 2, memory: 4096, storage: 16384 } : { cpu: 4, memory: 8192, storage: 32768 })
      return Response.json({ id })
    }
    const del = /^\/v5\/vms\/([^/]+)$/.exec(url.pathname)
    if (req.method === "DELETE" && del) return deleted.push(del[1]!), Response.json({})
    if ((req.method === "GET" || req.method === "PATCH") && del) {
      const m = made.find((x) => x.id === del[1])
      if (!m || deleted.includes(m.id)) return new Response("no such vm", { status: 404 })
      if (req.method === "PATCH") {
        const body = (await req.json()) as any
        patches.push({ vm: m.id, body })
      }
      const v = Object.assign({}, m.body, ...patches.filter((p) => p.vm === m.id).map((p) => p.body))
      return Response.json({ id: m.id, state: states.get(m.id) ?? "running", ipMode: "dualStack", resources: sizes.get(m.id), metadata: v.metadata ?? {}, displayName: v.displayName ?? null, idleTimeoutSeconds: v.idleTimeoutSeconds ?? null, ttlSeconds: v.ttlSeconds ?? null })
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
      if (body.command.startsWith("/opt/chief-cc/boot.sh ")) await wait(latency.boot)
      if (body.command === "bash -s") await wait(latency.net)
      events.push({ name: body.command.split(" ")[0]!, at: Date.now() })
      if (body.command.startsWith("/opt/chief-cc/boot.sh ")) return boots.push({ vm, stdin }), bootFails?.(boots.length) ? Response.json({ statusCode: 1, stdout: "" }) : Response.json({ statusCode: 0, stdout: "ready\n" })
      if (body.command === "bash -s") return nets.push({ vm, script: stdin }), Response.json({ statusCode: 0, stdout: "net ok\n" })
      const start = /^\/opt\/chief-cc\/start\.sh (run_[0-9]+)$/.exec(body.command)
      if (start) {
        const s: Started = { vm, run: start[1]!, input: JSON.parse(stdin) }
        started.push(s)
        // The turn machine: the stream, then the result, posted to the Worker as chief-turn-runner does.
        const n = started.length
        setTimeout(() => void (during ?? (async () => undefined))(s, n).then(() => ((a) => (typeof a === "string" ? machine(s, a) : a(s)))(answer(s.input.prompt, n))), 20)
        return Response.json({ statusCode: 0, stdout: "started\n" })
      }
      execs.push({ vm, command: body.command, stdin: raw })
      if (body.command.includes("resize2fs")) return Response.json({ statusCode: 0, stdout: "/dev/vda 63G 1.2G 62G 2% /\n" })
      return Response.json({ statusCode: 0, stdout: body.command.startsWith("echo ") ? `${body.command.slice(5)}\n` : "" })
    }
    return new Response("unexpected", { status: 500 })
  })
  return { events, made, deleted, boots, started, nets, steps, keys, tags, other, execs, sizes, resizes, identities, tokens, execAuth, states, patches, files, uploads, snapshots, lifecycle }
}

export const notes = (s: Started, body: unknown, token = s.input.token) => worker.fetch(s.input.notes_url, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) })
export const machine = async (s: Started, reply: string) => {
  const half = Math.floor(reply.length / 2)
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_start" }, { gen: 0, type: "text_delta", delta: reply.slice(0, half) }] })
  await notes(s, { run: s.run, events: [{ gen: 0, type: "text_delta", delta: reply.slice(half) }, { gen: 0, type: "text_done", text: reply }, { gen: 0, type: "done" }] })
  await notes(s, { run: s.run, result: { status: "done", reply, model: s.input.model, usage: { input: 3, output: 7, cache_read: 0, cache_write: 0 }, first_token_ms: 900, total_ms: 1500, last_gen: 0 } })
}
