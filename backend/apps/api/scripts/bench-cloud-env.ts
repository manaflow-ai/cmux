#!/usr/bin/env bun
/**
 * Cloud environments on the cmux-next provider path: cold boot (base image, then clone + setup on the
 * new machine) versus a boot from the environment's snapshot. Drives the real CloudDO driver stack
 * (FreestyleCloudProvider behind GuardedCloudDriver behind GuardedCloudSandbox) on the development
 * lane: names cmuxnp-dev-cld-, image cmuxnp-dev-vmimg-. Deletes every machine and the snapshot.
 *
 *   set -a; source ~/.secrets/cmux.env; set +a
 *   bun scripts/bench-cloud-env.ts [--trials 3] [--repo owner/name@ref] [--setup 'cmd'] [--image slug] [--out file.json]
 */
import { writeFileSync } from "node:fs"
import { awaitSandboxReady, buildEnvironmentSnapshot, environmentBootPlan, parseEnvironmentSpec } from "@cmux/cloud-env"
import { GuardedCloudDriver } from "../src/cloud-driver.ts"
import { FreestyleCloudProvider } from "../src/providers/freestyle/cloud.ts"
import { GuardedCloudSandbox } from "../src/cloud-env-sandbox.ts"

const args = process.argv.slice(2)
const opt = (f: string) => { const i = args.indexOf(f); return i === -1 ? undefined : args[i + 1] }
const trials = Number(opt("--trials") ?? "3")
const repo = opt("--repo") ?? "manaflow-ai/cmux@feat-cmux-next"
const setup = opt("--setup") ?? "cd web && bun install --frozen-lockfile"
const image = opt("--image") ?? "cmuxnp-dev-vmimg-ci-40270232246-1"
const outPath = opt("--out")
const prefix = "cmuxnp-dev-cld-"
const key = process.env.FREESTYLE_API_KEY?.trim()
if (!key) { console.error("FREESTYLE_API_KEY is required (source ~/.secrets/cmux.env)"); process.exit(2) }
const parsed = parseEnvironmentSpec({ name: "bench", repo, setupScript: setup, env: [{ name: "BENCH_ENV", value: "1" }] })
if (!parsed.ok) { console.error(parsed.error.message); process.exit(2) }
const spec = parsed.spec
const rand = () => [...crypto.getRandomValues(new Uint8Array(20))].map((b) => "abcdefghijklmnopqrstuvwxyz0123456789"[b % 36]).join("")
const tag = { team: "team_envbench", machine: `vm_${rand()}` }
const sandbox = new GuardedCloudSandbox(new GuardedCloudDriver(new FreestyleCloudProvider(key, "https://api.freestyle.sh", image), prefix), tag, "freestyle")
const now = () => performance.now()
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))
const live = new Set<string>()
const ready = spec.repo ? `test -d "$HOME/work/${spec.repo.name}/.git" && test -f "$HOME/.cmux/environment.json"` : `test -f "$HOME/.cmux/environment.json"`

const report: Record<string, unknown> = { repo, setup, image, startedAt: new Date().toISOString() }
let snapshot: string | null = null
let ok = false
try {
  const builderName = `${prefix}vm-${rand()}`
  live.add(builderName)
  const built = await buildEnvironmentSnapshot(sandbox, spec, { baseImage: image, builderName, snapshotName: `${prefix}snap-${rand()}`, warmName: `${prefix}vm-${rand()}`, now, sleep })
  live.delete(builderName)
  snapshot = built.snapshotId
  report.build = built.timings
  report.coldBootToReadyMs = built.timings.bootMs + built.timings.readyMs + built.timings.setupMs
  console.error(`build ${JSON.stringify(built.timings)}`)
  const plan = await environmentBootPlan(spec, { snapshotId: built.snapshotId, digest: built.digest, provider: "freestyle" }, image, "freestyle")
  if (plan.kind !== "snapshot") throw new Error("boot plan is not a snapshot boot")
  const boots: Array<{ bootMs: number; readyMs: number }> = []
  for (let i = 0; i < trials; i++) {
    const name = `${prefix}vm-${rand()}`
    const t0 = now()
    live.add(name)
    await sandbox.boot({ name, snapshot: plan.snapshotId })
    const bootMs = now() - t0
    await awaitSandboxReady(sandbox, name, { timeoutMs: 180_000, intervalMs: 250, now, sleep })
    for (;;) {
      const r = await sandbox.exec(name, ready, 30_000).catch(() => null)
      if (r?.exitCode === 0) break
      if (now() - t0 > 180_000) throw new Error("snapshot machine never had the checkout")
      await sleep(250)
    }
    boots.push({ bootMs, readyMs: now() - t0 })
    console.error(`snapshot boot ${i + 1}: ${JSON.stringify(boots.at(-1))}`)
    await sandbox.destroy(name)
    live.delete(name)
  }
  const sorted = boots.map((b) => b.readyMs).sort((a, b) => a - b)
  report.snapshotBoots = boots
  report.summary = { coldBootToReadyMs: Math.round(report.coldBootToReadyMs as number), snapshotReadyP50Ms: Math.round(sorted[Math.floor(sorted.length / 2)] ?? 0), snapshotReadyMaxMs: Math.round(sorted.at(-1) ?? 0) }
  ok = true
} catch (e) {
  const err = e as { stage?: string; logTail?: string; message?: string }
  console.error("bench failed:", err.stage ?? "", err.message, err.logTail ?? "")
  report.error = { stage: err.stage, message: err.message, logTail: err.logTail }
} finally {
  for (const name of live) await sandbox.destroy(name).catch((e) => { console.error(`destroy ${name} failed`, e); ok = false })
  if (snapshot) {
    const raw = new FreestyleCloudProvider(key, "https://api.freestyle.sh", image)
    const found = await raw.findSnapshot(snapshot).catch(() => null)
    if (found) await raw.deleteSnapshot(found.id).catch((e) => { console.error(`snapshot ${snapshot} delete failed`, e); ok = false })
  }
  report.ok = ok
  const text = JSON.stringify(report, null, 2)
  if (outPath) writeFileSync(outPath, text + "\n")
  console.log(text)
  process.exit(ok ? 0 : 1)
}
