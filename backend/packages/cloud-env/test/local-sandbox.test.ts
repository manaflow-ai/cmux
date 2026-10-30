import { spawn } from "node:child_process"
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, test } from "vitest"
import { buildEnvironmentSnapshot, environmentBootPlan, type CloudSandbox, type SandboxBootOptions, type SandboxExecResult } from "../src/index.ts"
import { BASE, spec } from "./fixtures.ts"

/**
 * A CloudSandbox whose machines are directories and whose exec is real bash: the detached build,
 * its polling and the snapshot boot run end to end with no provider. A snapshot is a copy of the
 * machine's home; a boot from it copies it back.
 */
class LocalSandbox implements CloudSandbox {
  readonly provider = "local"
  private readonly root = mkdtempSync(join(tmpdir(), "cmux-env-local-"))
  private n = 0
  readonly snapshots = new Map<string, string>()

  async boot(o: SandboxBootOptions) {
    const id = `vm-${++this.n}`
    const home = join(this.root, id)
    if (o.snapshot) cpSync(this.snapshots.get(o.snapshot)!, home, { recursive: true })
    else mkdirSync(home)
    return { id }
  }

  exec(id: string, command: string): Promise<SandboxExecResult> {
    const home = join(this.root, id)
    return new Promise((resolve) => {
      const child = spawn("bash", ["-c", command], { env: { ...process.env, HOME: "/nonexistent", CMUX_ENVIRONMENT_HOME: home, CMUX_ENVIRONMENT_PROFILE_DIR: join(home, ".profile.d"), CMUX_ENVIRONMENT_SUDO: "" } })
      let stdout = ""
      let stderr = ""
      child.stdout.on("data", (d) => (stdout += d))
      child.stderr.on("data", (d) => (stderr += d))
      child.on("close", (code) => resolve({ exitCode: code ?? 1, stdout, stderr }))
    })
  }

  async snapshot(id: string, name: string) {
    const dir = join(this.root, `snap-${name}`)
    cpSync(join(this.root, id), dir, { recursive: true })
    this.snapshots.set(name, dir)
    return { id: name }
  }

  async destroy(id: string) {
    rmSync(join(this.root, id), { recursive: true, force: true })
  }

  home(id: string) {
    return join(this.root, id)
  }
}

describe("a full build in real bash", () => {
  test("detached setup runs to the end, the snapshot holds its work, and a snapshot boot has it without running setup", async () => {
    const box = new LocalSandbox()
    const s = spec({ repo: null, setupScript: 'sleep 0.3; echo built > "$HOME/work/artifact"; echo "setup log line"' })
    const out = await buildEnvironmentSnapshot(box, s, { baseImage: BASE, builderName: "b", snapshotName: "s1", setupPollMs: 50, readyIntervalMs: 10, warmName: null })
    const plan = await environmentBootPlan(s, { snapshotId: out.snapshotId, digest: out.digest, provider: "local" }, BASE, "local")
    if (plan.kind !== "snapshot") throw new Error("expected a snapshot boot")
    const vm = await box.boot({ name: "ws", snapshot: plan.snapshotId })
    expect(readFileSync(join(box.home(vm.id), "work", "artifact"), "utf8")).toBe("built\n")
    expect(JSON.parse(readFileSync(join(box.home(vm.id), ".cmux", "environment.json"), "utf8")).digest).toBe(out.digest)
    expect(readFileSync(join(box.home(vm.id), ".cmux", "environment-build.log"), "utf8")).toContain("setup log line")
  })

  test("a failing detached setup reports its exit code and log", async () => {
    const box = new LocalSandbox()
    const err = await buildEnvironmentSnapshot(box, spec({ repo: null, setupScript: "echo nope; exit 5" }), { baseImage: BASE, builderName: "b", snapshotName: "s1", setupPollMs: 50, readyIntervalMs: 10 }).catch((e: unknown) => e)
    expect(err).toMatchObject({ stage: "setup", message: "setup exited 5" })
    expect((err as { logTail: string }).logTail).toContain("nope")
    expect(box.snapshots.size).toBe(0)
  })
})
