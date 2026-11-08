import { createHash } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"
import { describe, expect, it } from "vitest"
import { DEFAULT_HAND_GUEST_CONFIG } from "../src/chief-default-hand.ts"
import { handInstallScript } from "../src/hand-install.ts"
import type { Env } from "../src/env.ts"

describe("default Chief hand guest config", () => {
  it("creates a private bearer only on the guest and retries with the same SHA", () => {
    const home = mkdtempSync(join(tmpdir(), "chief-hand-guest-"))
    try {
      const input = { api: "https://api.test", hand: "hand_aaaaaaaaaaaaaaaaaaaa", scope: "owner/chief/machine/install" }
      const run = (value = input) => spawnSync("python3", ["-c", DEFAULT_HAND_GUEST_CONFIG], { input: JSON.stringify(value), encoding: "utf8", env: { ...process.env, HOME: home } })
      const first = run()
      expect(first.status, first.stderr).toBe(0)
      const file = join(home, ".cmux-chief-hand", "hand.json")
      const config = JSON.parse(readFileSync(file, "utf8")) as { key: string; agent_policy: string }
      const key = config.key
      expect(key).toMatch(/^[A-Za-z0-9_-]{43}$/)
      expect(statSync(file).mode & 0o777).toBe(0o600)
      expect(JSON.parse(first.stdout)).toEqual({ key_sha: createHash("sha256").update(key).digest("hex"), cwd: join(home, "proj") })
      expect(first.stdout + first.stderr).not.toContain(key)
      config.agent_policy = "deny-all"
      writeFileSync(file, JSON.stringify(config))
      const repeated = run()
      expect(repeated.status, repeated.stderr).toBe(0)
      expect(repeated.stdout).toBe(first.stdout)
      expect(JSON.parse(readFileSync(file, "utf8"))).toMatchObject({ key, agent_policy: "deny-all" })
      const conflict = run({ ...input, scope: "different/install" })
      expect(conflict.status).not.toBe(0)
      expect(conflict.stdout).toBe("")
      expect(conflict.stderr).not.toContain(key)
      expect(JSON.parse(readFileSync(file, "utf8"))).toMatchObject({ key, agent_policy: "deny-all" })
    } finally { rmSync(home, { recursive: true, force: true }) }
  })

  it("repairs an installation from existing config without redeeming a pairing code", async () => {
    const home = mkdtempSync(join(tmpdir(), "chief-hand-installer-"))
    try {
      const script = await (await handInstallScript({} as Env, "https://api.test")).text()
      const binary = join(home, "test-binary")
      writeFileSync(binary, "#!/bin/sh\nprintf paired >\"$HOME/pair-called\"\n")
      chmodSync(binary, 0o755)
      const run = () => spawnSync("sh", ["-s", "--", "--configured", "--no-service", "--binary", binary], { input: script, encoding: "utf8", env: { ...process.env, HOME: home, CMUX_HAND_HOME: join(home, ".cmux-chief-hand") } })
      expect(run().status).not.toBe(0)
      mkdirSync(join(home, ".cmux-chief-hand"), { recursive: true })
      writeFileSync(join(home, ".cmux-chief-hand", "hand.json"), "{}", { mode: 0o600 })
      const configured = run()
      expect(configured.status, configured.stderr).toBe(0)
      expect(existsSync(join(home, "pair-called"))).toBe(false)
    } finally { rmSync(home, { recursive: true, force: true }) }
  })

  it.skipIf(process.platform !== "linux")("releases the service lock when the Hand exits while its daemon survives", async () => {
    const home = mkdtempSync(join(tmpdir(), "chief-hand-lock-"))
    let daemon: number | undefined
    try {
      const script = await (await handInstallScript({} as Env, "https://api.test")).text()
      const fallback = script.split("\n").find((line) => line.includes("nohup flock "))!
      const binary = join(home, "test-hand")
      writeFileSync(binary, '#!/bin/sh\nsleep 30 &\nprintf "%s" "$!" > "$HOME_DIR/daemon.pid"\n')
      chmodSync(binary, 0o755)
      const started = spawnSync("sh", ["-c", `${fallback}\nwait`], {
        encoding: "utf8", timeout: 5000,
        env: { ...process.env, HOME_DIR: home, BIN: binary, LOG: join(home, "hand.log") },
      })
      expect(started.status, started.stderr).toBe(0)
      daemon = Number(readFileSync(join(home, "daemon.pid"), "utf8"))
      expect(Number.isSafeInteger(daemon) && daemon > 0).toBe(true)
      process.kill(daemon, 0)
      const replacement = spawnSync("flock", ["-n", join(home, "run.lock"), "true"], { encoding: "utf8", timeout: 5000 })
      expect(replacement.status, replacement.stderr).toBe(0)
    } finally {
      if (daemon !== undefined && Number.isSafeInteger(daemon) && daemon > 0) {
        try { process.kill(daemon, "SIGTERM") } catch { /* The test daemon may already have exited. */ }
      }
      rmSync(home, { recursive: true, force: true })
    }
  })
})
