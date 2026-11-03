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
})
