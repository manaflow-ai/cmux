/**
 * Live measurement against Freestyle (not run in CI). Creates a throwaway
 * team network (VPC, one tunnel, rules) plus one VM with a 1 h TTL, brings the
 * tunnel up with the real cmux-wg userspace hub (`cmux wg hub`), and measures:
 * tunnel create, firewall apply propagation, rule removal propagation and
 * device revoke propagation. Everything it creates carries the cmux-np marker
 * or the throwaway team slug and is torn down at the end; ids are written to a
 * ledger file first so a crash can be cleaned up with `--cleanup <ledger>`.
 *
 *   FREESTYLE_API_KEY=… CMUX_WG_BIN=~/.local/bin/cmux-tui bun scripts/live-freestyle.ts
 */
import { execFileSync, spawn, type ChildProcess } from "node:child_process"
import { randomBytes } from "node:crypto"
import { appendFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { connect, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { compileNetwork, createFreestyleClient, parsePolicy, reconcile, teardown, vpcSlug, type Directory } from "../src/index.ts"

const KEY = process.env.FREESTYLE_API_KEY
const BASE = process.env.FREESTYLE_API_URL_V5 ?? "https://api.freestyle.sh"
const WG_BIN = process.env.CMUX_WG_BIN ?? `${process.env.HOME}/.local/bin/cmux-tui`
if (!KEY) throw new Error("FREESTYLE_API_KEY is required")

const calls: Array<{ method: string; path: string; status: number; ms: number }> = []
const api = createFreestyleClient({ apiKey: KEY, baseUrl: BASE, onCall: (c) => calls.push(c), timeoutMs: 30_000 })

const raw = async <T>(method: string, path: string, body?: unknown): Promise<T> => {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${KEY}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(180_000)
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text.slice(0, 300)}`)
  return (text ? JSON.parse(text) : null) as T
}

const log = (...a: Array<unknown>) => console.log(new Date().toISOString().slice(11, 23), ...a)
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ---- cleanup mode -----------------------------------------------------------
if (process.argv[2] === "--cleanup") {
  const lines = readFileSync(process.argv[3]!, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { kind: string; id: string })
  for (const l of lines.filter((x) => x.kind === "team")) log("teardown", l.id, JSON.stringify(await teardown(api, { team: l.id, env: "dev" })))
  for (const l of lines.filter((x) => x.kind === "vm")) await raw("DELETE", `/v5/vms/${l.id}`).then(() => log("deleted vm", l.id), (e) => log("vm delete", String(e)))
  process.exit(0)
}

const dir0 = mkdtempSync(join(tmpdir(), "cmux-np-live-"))
const ledger = join(dir0, "ledger.jsonl")
const record = (kind: string, id: string) => appendFileSync(ledger, `${JSON.stringify({ kind, id })}\n`)
log("ledger", ledger)

const rand = (n: number) => randomBytes(n).toString("hex").slice(0, n)
const team = `team_${rand(20)}`
const user = `user_${rand(20)}`
const install = `inst_${rand(20)}`
record("team", team)
// Dev namespace in the shared account: cmuxnp-dev- prefix, 1 h expiry; the hourly cleanup removes leftovers.
const scope = { team, env: "dev" as const, ttlMs: 3600_000 }

const priv = execFileSync("wg", ["genkey"]).toString().trim()
const pub = execFileSync("wg", ["pubkey"], { input: priv }).toString().trim()

const policyText = (ports: string) => `{
  "groups": { "group:admins": ["user:np"] },
  "tagOwners": { "tag:team-vm": ["group:admins"] },
  "acls": [ { "action": "accept", "src": ["group:admins"], "dst": ["tag:team-vm:22,${ports}"] } ],
  "ssh": [ { "action": "accept", "src": ["group:admins"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"] } ],
  "tests": [ { "src": "user:np", "accept": ["tag:team-vm:22"], "deny": ["tag:team-vm:9999"] } ]
}`

let directory: Directory = {
  members: [{ user, role: "owner", handle: "np" }],
  devices: [{ install, user, wg_public_key: pub }],
  machines: []
}

const compile = (ports: string) => {
  const p = parsePolicy(policyText(ports))
  if (!p.ok) throw new Error(JSON.stringify(p.issues))
  return compileNetwork(p.value, directory)
}

const summarize = (r: Awaited<ReturnType<typeof reconcile>>) => ({
  passes: r.passes,
  converged: r.converged,
  ms: r.ms,
  actions: r.outcomes.map((o) => `${o.action.op}${o.ok ? "" : `!${o.error?.status}`} ${o.ms}ms`),
  deferred: r.deferred.length
})

const results: Record<string, unknown> = { team }
let hub: ChildProcess | undefined
let sock = ""
let target = ""
let conf = ""
let vmId: string | undefined

/** SOCKS5 CONNECT through the hub's unix socket; resolves with ms to the CONNECT reply, or the failure. */
const probe = (sock: string, host: string, port: number, timeoutMs = 2500, keep = false): Promise<{ ok: boolean; ms: number; detail: string; socket?: Socket }> =>
  new Promise((resolve) => {
    const t0 = Date.now()
    const s = connect(sock)
    let stage = 0
    const done = (ok: boolean, detail: string) => {
      clearTimeout(timer)
      if (!(ok && keep)) s.destroy()
      resolve({ ok, ms: Date.now() - t0, detail, ...(ok && keep ? { socket: s } : {}) })
    }
    const timer = setTimeout(() => done(false, "timeout"), timeoutMs)
    s.on("error", (e) => done(false, String(e)))
    s.on("connect", () => s.write(Buffer.from([5, 1, 0])))
    s.on("data", (d) => {
      if (stage === 0) {
        stage = 1
        const v4 = host.split(".").map(Number)
        const req = v4.length === 4 ? Buffer.from([5, 1, 0, 1, ...v4, port >> 8, port & 255]) : Buffer.concat([Buffer.from([5, 1, 0, 3, host.length]), Buffer.from(host), Buffer.from([port >> 8, port & 255])])
        s.write(req)
      } else if (stage === 1) {
        stage = 2
        done(d[1] === 0, `socks reply ${d[1]}`)
      }
    })
  })

/** Polls until `want` holds; returns ms until it did (or null at the deadline). */
const until = async (fn: () => Promise<boolean>, deadlineMs: number, everyMs = 150): Promise<number | null> => {
  const t0 = Date.now()
  while (Date.now() - t0 < deadlineMs) {
    if (await fn()) return Date.now() - t0
    await sleep(everyMs)
  }
  return null
}

try {
  // 1. Network for the team: VPC + tunnel (no machine yet).
  const r1 = await reconcile(api, scope, compile("8081"), directory)
  results.first_reconcile = summarize(r1)
  log("reconcile 1", results.first_reconcile)
  if (!r1.vpc) throw new Error("no vpc")
  record("vpc", r1.vpc.id)
  const tun = r1.tunnels[0]
  if (!tun) throw new Error("no tunnel")
  record("tunnel", tun.tunnelId)

  // 2. A VM in the VPC with two listeners. TTL makes Freestyle delete it even if this script dies.
  const tVm = Date.now()
  const vm = await raw<{ id: string; vpcs?: Array<{ ipv4?: string; ipv6?: string }> }>("POST", "/v5/vms", {
    displayName: `cmuxnp-dev live ${team.slice(5, 13)}`,
    ttlSeconds: 3600,
    metadata: { cmuxnp_env: "dev", cmuxnp_team: team.slice(5, 17) },
    firewall: { rules: [] },
    vpcs: [{ vpcId: r1.vpc.id }]
  })
  vmId = vm.id
  record("vm", vm.id)
  results.vm_create_ms = Date.now() - tVm
  const vmData = await raw<{ vpcs?: Array<{ ipv4?: string | null; ipv6?: string | null }> }>("GET", `/v5/vms/${vm.id}`)
  const vmV4 = vmData.vpcs?.[0]?.ipv4 ?? null
  const vmV6 = vmData.vpcs?.[0]?.ipv6 ?? null
  log("vm", vm.id, vmV4, vmV6, `${results.vm_create_ms}ms`)
  const ex = await raw<{ stdout?: string; stderr?: string; statusCode?: number }>("POST", `/v5/vms/${vm.id}/exec-await`, {
    command: `(command -v python3 || true); for p in 8080 8081; do nohup python3 -m http.server $p --bind :: >/dev/null 2>&1 & done; sleep 1; (ss -ltn 2>/dev/null || netstat -ltn) | head -20; ping -c1 -W1 ${vmV4?.replace(/\.\d+$/, ".1") ?? "127.0.0.1"} >/dev/null 2>&1; echo ok`,
    timeoutMs: 30_000
  })
  log("exec", ex.statusCode, (ex.stdout ?? "").trim().replaceAll("\n", " | "), (ex.stderr ?? "").slice(0, 200))

  // 3. Bind the machine and reconcile: rules to vm:22 and vm:8081 only.
  directory = { ...directory, machines: [{ id: "mach_teamvm", provider_id: vm.id, tags: ["team-vm"], ...(vmV4 ? { address: vmV4 } : {}) }] }
  const r2 = await reconcile(api, scope, compile("8081"), directory, { expectConverged: false })
  results.bind_machine = summarize(r2)
  log("reconcile 2", results.bind_machine)

  // 4. Bring the tunnel up in userspace with the real hub.
  conf = join(dir0, "wg.conf")
  writeFileSync(conf, r2.tunnels[0]!.clientConfig.replace(/^PrivateKey\s*=.*$/m, `PrivateKey = ${priv}`), { mode: 0o600 })
  sock = join(dir0, "hub.sock")
  const tHub = Date.now()
  hub = spawn(WG_BIN, ["wg", "hub", "--config", conf, "--socket", sock], { stdio: ["ignore", "pipe", "pipe"] })
  hub.stderr!.on("data", (d) => appendFileSync(join(dir0, "hub.log"), d))
  hub.stdout!.on("data", (d) => appendFileSync(join(dir0, "hub.log"), d))
  target = vmV4 ?? vmV6!
  const firstOk = await until(async () => (await probe(sock, target, 8081)).ok, 60_000, 250)
  results.hub_first_connect_ms = firstOk === null ? null : Date.now() - tHub
  log("first allowed connect (8081) after hub start", results.hub_first_connect_ms)
  const denied = await probe(sock, target, 8080)
  results.denied_port_before_rule = denied
  log("8080 before rule (expect fail)", denied)

  // 5-6. Firewall apply and rule removal, repeated. A dropped packet shows up only as a timeout,
  // so probes start every 50 ms and run concurrently; the flip time is the start offset of the
  // first probe of a stable run in the new state, relative to the reconcile start.
  const flip = async (port: number, wantOk: boolean, trigger: () => Promise<unknown>) => {
    const t0 = Date.now()
    const samples: Array<{ at: number; ok: boolean }> = []
    let stop = false
    const loop = (async () => {
      const inflight: Array<Promise<void>> = []
      while (!stop && Date.now() - t0 < 20_000) {
        const at = Date.now() - t0
        inflight.push(probe(sock, target, port, 1000).then((r) => void samples.push({ at, ok: r.ok })))
        await sleep(50)
      }
      await Promise.all(inflight)
    })()
    await trigger()
    const triggerMs = Date.now() - t0
    // Stop once 10 consecutive (by start time) samples show the new state.
    for (;;) {
      await sleep(200)
      const sorted = [...samples].sort((a, b) => a.at - b.at)
      let run = 0
      let first: number | null = null
      for (const x of sorted) {
        if (x.ok === wantOk) {
          if (run === 0) first = x.at
          run++
        } else run = 0
      }
      if (run >= 10 || Date.now() - t0 > 20_000) {
        stop = true
        await loop
        const lastOld = sorted.filter((x) => x.ok !== wantOk).map((x) => x.at).pop() ?? null
        return { trigger_ms: triggerMs, flip_ms: run >= 10 ? first : null, last_old_state_probe_ms: lastOld }
      }
    }
  }
  const applies: Array<unknown> = []
  const removes: Array<unknown> = []
  for (let i = 0; i < 5; i++) {
    applies.push(await flip(8080, true, () => reconcile(api, scope, compile("8080,8081"), directory)))
    removes.push(await flip(8080, false, () => reconcile(api, scope, compile("8081"), directory)))
  }
  results.firewall_apply = applies
  results.rule_remove = removes
  log("apply", JSON.stringify(applies))
  log("remove", JSON.stringify(removes))

  // Does an established connection survive a rule removal?
  await reconcile(api, scope, compile("8080,8081"), directory)
  await until(async () => (await probe(sock, target, 8080, 1000)).ok, 10_000, 100)
  const held = await probe(sock, target, 8080, 2500, true)
  await reconcile(api, scope, compile("8081"), directory)
  await sleep(1500)
  const alive = async (sk?: Socket) =>
    sk
      ? new Promise<boolean>((resolve) => {
          sk.write("GET / HTTP/1.0\r\n\r\n")
          sk.once("data", () => resolve(true))
          sk.once("close", () => resolve(false))
          sk.once("error", () => resolve(false))
          setTimeout(() => resolve(false), 3000)
        }).finally(() => sk.destroy())
      : null
  results.established_survives_rule_remove = await alive(held.socket)
  log("established survives rule remove", results.established_survives_rule_remove)

  // 7. Device revoke (tunnel delete), with an established connection open.
  const held2 = await probe(sock, target, 8081, 2500, true)
  const revoke = await flip(8081, false, () => {
    directory = { ...directory, devices: directory.devices.map((d) => ({ ...d, revoked: true })) }
    return reconcile(api, scope, compile("8081"), directory)
  })
  results.revoke = { ...revoke, established_survives: await alive(held2.socket) }
  log("revoke", results.revoke)
  hub.kill("SIGTERM")

  // 8. Re-join: a new tunnel for the same device key, then a fresh hub.
  directory = { ...directory, devices: directory.devices.map((d) => ({ ...d, revoked: false })) }
  const tJoin = Date.now()
  const rj = await reconcile(api, scope, compile("8081"), directory)
  const joinReconcile = Date.now() - tJoin
  writeFileSync(conf, rj.tunnels[0]!.clientConfig.replace(/^PrivateKey\s*=.*$/m, `PrivateKey = ${priv}`), { mode: 0o600 })
  const sock2 = join(dir0, "hub2.sock")
  hub = spawn(WG_BIN, ["wg", "hub", "--config", conf, "--socket", sock2], { stdio: ["ignore", "pipe", "pipe"] })
  hub.stderr!.on("data", (d) => appendFileSync(join(dir0, "hub.log"), d))
  const joinOk = await until(async () => (await probe(sock2, target, 8081, 1000)).ok, 30_000, 100)
  results.rejoin = { reconcile: summarize(rj), reconcile_ms: joinReconcile, first_connect_after_hub_start_ms: joinOk, total_ms: Date.now() - tJoin }
  log("rejoin", results.rejoin)
} catch (e) {
  results.error = String(e instanceof Error ? e.stack : e)
  log("ERROR", results.error)
} finally {
  hub?.kill("SIGTERM")
  const td = await teardown(api, scope)
  results.teardown = td.map((o) => `${o.action.op}${o.ok ? "" : "!"} ${o.ms}ms`)
  if (vmId) await raw("DELETE", `/v5/vms/${vmId}`).then(() => (results.vm_deleted = true), (e) => (results.vm_deleted = String(e)))
  // The VPC refuses deletion for a few seconds after its VM goes ("has reserved addresses"); retry.
  for (let i = 0; i < 10; i++) {
    const again = await teardown(api, scope)
    if (again.every((o) => o.ok)) break
    await sleep(2000)
  }
  results.leftover = await api.getVpc(vpcSlug(scope)).then((v) => (v ? v.id : null))
  results.calls = Object.entries(
    calls.reduce<Record<string, Array<number>>>((acc, c) => {
      const k = `${c.method} ${c.path.replace(/\?.*$/, "")} ${c.status}`
      ;(acc[k] ??= []).push(c.ms)
      return acc
    }, {})
  ).map(([k, v]) => `${k} n=${v.length} p50=${v.sort((a, b) => a - b)[Math.floor(v.length / 2)]}ms max=${Math.max(...v)}ms`)
  writeFileSync(join(dir0, "results.json"), JSON.stringify(results, null, 2))
  console.log(JSON.stringify(results, null, 2))
  log("results", join(dir0, "results.json"), "hub log", join(dir0, "hub.log"))
}
