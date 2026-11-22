import { createHash } from "node:crypto"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { spawnSync } from "node:child_process"
import { describe, expect, it } from "vitest"
import { DEFAULT_HAND_GUEST_CONFIG, followDefaultCarrier, type DefaultChiefMachine } from "../src/chief-default-hand.ts"
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

  it("gives a home copied from the machine's earlier VM a new identity, and nothing else", () => {
    const home = mkdtempSync(join(tmpdir(), "chief-hand-moved-"))
    try {
      const scope = (vm: string, install: string, owner = "user_1") => JSON.stringify([owner, "agent_1", "chief-default-user_1", "team_1", "logical", "freestyle", vm, install])
      const input = { api: "https://api.test", hand: "hand_aaaaaaaaaaaaaaaaaaaa", scope: scope("vm_old", "inst_old") }
      const run = (value: typeof input) => spawnSync("python3", ["-c", DEFAULT_HAND_GUEST_CONFIG], { input: JSON.stringify(value), encoding: "utf8", env: { ...process.env, HOME: home } })
      expect(run(input).status).toBe(0)
      const file = join(home, ".cmux-chief-hand", "hand.json")
      const old = JSON.parse(readFileSync(file, "utf8")) as { key: string; agent_policy: string }
      writeFileSync(file, JSON.stringify({ ...old, agent_policy: "approve-reads" }), { mode: 0o600 })
      // Another owner's or another machine's scope stays a conflict and leaves the file alone.
      for (const other of [scope("vm_new", "inst_new", "user_2"), JSON.stringify(["user_1", "agent_1", "chief-default-user_1", "team_1", "other", "freestyle", "vm_new", "inst_new"])]) {
        const refused = run({ ...input, hand: "hand_bbbbbbbbbbbbbbbbbbbb", scope: other })
        expect(refused.status).not.toBe(0)
        expect(JSON.parse(readFileSync(file, "utf8"))).toMatchObject({ key: old.key, hand: input.hand })
      }
      expect(run({ ...input, api: "https://elsewhere.test", hand: "hand_bbbbbbbbbbbbbbbbbbbb", scope: scope("vm_new", "inst_new") }).status).not.toBe(0)
      const moved = run({ ...input, hand: "hand_bbbbbbbbbbbbbbbbbbbb", scope: scope("vm_new", "inst_new") })
      expect(moved.status, moved.stderr).toBe(0)
      const config = JSON.parse(readFileSync(file, "utf8")) as { key: string; hand: string; default_scope: string; agent_policy: string }
      expect(config).toMatchObject({ hand: "hand_bbbbbbbbbbbbbbbbbbbb", default_scope: scope("vm_new", "inst_new"), agent_policy: "approve-reads" })
      expect(config.key).not.toBe(old.key)
      expect(statSync(file).mode & 0o777).toBe(0o600)
      expect(JSON.parse(moved.stdout)).toEqual({ key_sha: createHash("sha256").update(config.key).digest("hex"), cwd: join(home, "proj") })
      expect(moved.stdout + moved.stderr).not.toContain(config.key)
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

  it("restarts a configured systemd hand so it reads a replaced hand.json; a paired one keeps running", async () => {
    const script = await (await handInstallScript({} as Env, "https://api.test")).text()
    const lines = script.split("\n")
    const enable = lines.findIndex((line) => line.includes("systemctl --user enable --now"))
    expect(lines[enable + 2]).toBe('  [ "$CONFIGURED" != 1 ] || systemctl --user restart "$SERVICE_NAME.service"')
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

describe("default Chief follows its machine to a new VM", () => {
  const old: DefaultChiefMachine = { workspace: "chief-default-user_1", team: "team_1", machine: "logical", provider: "freestyle", connection_machine: "vm_old", install: "inst_old" }
  const next: DefaultChiefMachine = { ...old, connection_machine: "vm_new", install: "inst_new" }
  const authorize = (good: string) => async (b: DefaultChiefMachine) => { if (b.connection_machine !== good) throw new Error("chief.machine.carrier_changed") }

  it("keeps a binding that answers and never asks for a rebind", async () => {
    let asked = 0
    expect(await followDefaultCarrier(old, authorize("vm_old"), async () => { asked++; return { ok: true, changed: true, binding: next } })).toEqual(old)
    expect(asked).toBe(0)
  })

  it("follows a moved VM or a revoked old install to the platform's current VM", async () => {
    expect(await followDefaultCarrier(old, authorize("vm_new"), async () => ({ ok: true, changed: true, binding: next }))).toEqual(next)
    const revoked = async (b: DefaultChiefMachine) => { if (b.install === "inst_old") throw new Error("chief.machine.install_revoked") }
    expect(await followDefaultCarrier(old, revoked, async () => ({ ok: true, changed: true, binding: next }))).toEqual(next)
  })

  it("keeps the original refusal when nothing moved, the rebind is refused or fails, or the error is another one", async () => {
    const changed = authorize("vm_none")
    await expect(followDefaultCarrier(old, changed, async () => ({ ok: true, changed: false, binding: old }))).rejects.toThrow("chief.machine.carrier_changed")
    await expect(followDefaultCarrier(old, changed, async () => ({ ok: false, code: "chief.provision.machine_binding_pending", retryable: true }))).rejects.toThrow("chief.machine.carrier_changed")
    await expect(followDefaultCarrier(old, changed, async () => { throw new Error("transport") })).rejects.toThrow("chief.machine.carrier_changed")
    let asked = 0
    const offline = async () => { throw new Error("chief.machine.carrier_unavailable") }
    await expect(followDefaultCarrier(old, offline, async () => { asked++; return { ok: true, changed: true, binding: next } })).rejects.toThrow("chief.machine.carrier_unavailable")
    expect(asked).toBe(0)
    // The new VM must pass the same checks.
    await expect(followDefaultCarrier(old, changed, async () => ({ ok: true, changed: true, binding: next }))).rejects.toThrow("chief.machine.carrier_changed")
  })
})
