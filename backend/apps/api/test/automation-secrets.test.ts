import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { machineStepCommand, runMachineStep, type MachineExec } from "../src/automation-machine.ts"

/** Per-automation secrets (AUTOMATIONS-SPEC section 12, models-scout): set and listed by who may edit; opened only for an open run; never in a read, the ledger or the command line. */

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; SCHEDULER_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default
const inDO = runInDurableObject as unknown as (stub: unknown, cb: (instance: any, state: DurableObjectState) => Promise<void>) => Promise<void>
const token = async (sub: string) =>
  new SignJWT({ email: `${sub}@example.com`, email_verified: true, name: sub })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${testEnv.STACK_PROJECT_ID}`)
    .setAudience(testEnv.STACK_PROJECT_ID)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))
const call = async (path: string, t: string, body: unknown) =>
  (await (await worker.fetch(`https://api.test${path}`, { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${t}` }, body: JSON.stringify(body) })).json()) as any
const op = (t: string, name: string, params: unknown, key: string = crypto.randomUUID()) => call("/v1/ops", t, { op: name, params, idempotency_key: key, origin: "user" })
const read = (t: string, name: string, params: unknown = {}) => call("/v1/read", t, { op: name, params })

const TOKEN = "catalog-token-0123456789-abcd"
const SA = '{\n  "type": "service_account",\n  "private_key": "-----BEGIN PRIVATE KEY-----\\nMIIE\\n"\n}'

describe("per-automation secrets (workerd)", { timeout: 60_000 }, () => {
  it("set, replace, list (names only), remove; a run gets them while open; the ledger never holds a value", async () => {
    const t = await token("auto-secret-1")
    const team = (await op(t, "user.ensure", {})).value.personal_team as string
    const a = await op(t, "automation.create", { name: "models-scout", triggers: [{ type: "webhook" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    expect(a.ok, JSON.stringify(a)).toBe(true)
    const automation = a.value.id as string

    const set = await op(t, "automation.secret.set", { automation, name: "MODELS_CATALOG_TOKEN", value: TOKEN }, "k1")
    expect(set.ok, JSON.stringify(set)).toBe(true)
    expect(set.value).toMatchObject({ name: "MODELS_CATALOG_TOKEN", hint: "abcd", generation: 1 })
    expect(JSON.stringify(set)).not.toContain(TOKEN)
    // A retry of the same request answers from the row, no second seal.
    expect((await op(t, "automation.secret.set", { automation, name: "MODELS_CATALOG_TOKEN", value: TOKEN }, "k1")).value).toMatchObject({ generation: 1 })
    expect((await op(t, "automation.secret.set", { automation, name: "GOOGLE_APPLICATION_CREDENTIALS_JSON", value: SA })).ok).toBe(true)
    expect((await op(t, "automation.secret.set", { automation, name: "MODELS_CATALOG_TOKEN", value: TOKEN + "2" })).value).toMatchObject({ generation: 2 })

    const list = await read(t, "automation.secret.list", { automation })
    expect(list.value, JSON.stringify(list)).toBeDefined()
    expect(list.value.secrets.map((s: { name: string }) => s.name)).toEqual(["GOOGLE_APPLICATION_CREDENTIALS_JSON", "MODELS_CATALOG_TOKEN"])
    // A multi-line value (a key file) gets no hint: its last characters say nothing and could be part of a key.
    expect(list.value.secrets[0].hint).toBeNull()
    expect(JSON.stringify(list)).not.toContain("BEGIN PRIVATE KEY")

    // Bad names and values are refused.
    expect((await op(t, "automation.secret.set", { automation, name: "lower", value: "x" })).ok).toBe(false)
    expect((await op(t, "automation.secret.set", { automation, name: "A_NUL", value: "a\u0000b" })).ok).toBe(false)

    const scheduler = testEnv.SCHEDULER_DO.get(testEnv.SCHEDULER_DO.idFromName(team))
    await inDO(scheduler, async (s, state) => {
      await s.ensureRunPolicy(team)
      const r = s.submitSystem("automation.deliver", { automation, trigger: a.value.triggers[0].id, delivery_id: "d-1" }, "deliver-d-1")
      const run = r.frames.find((f: { t: string }) => f.t === "result").value.id as string
      expect(await s.runSecrets(team, run)).toEqual({ GOOGLE_APPLICATION_CREDENTIALS_JSON: SA, MODELS_CATALOG_TOKEN: TOKEN + "2" })
      await s.reportRun(team, { run, state: "succeeded", step: 0 })
      expect(await s.runSecrets(team, run)).toEqual({})
      // Nothing in the DO's storage holds a value in clear text.
      const dump = JSON.stringify(state.storage.sql.exec("SELECT * FROM automation_secrets").toArray())
      expect(dump).not.toContain(TOKEN)
      for (const table of state.storage.sql.exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '_cf_%' AND name NOT LIKE 'sqlite_%'").toArray()) {
        const rows = JSON.stringify(state.storage.sql.exec(`SELECT * FROM "${table.name}"`).toArray())
        expect(rows.includes(TOKEN), table.name).toBe(false)
        expect(rows.includes("BEGIN PRIVATE KEY"), table.name).toBe(false)
      }
    })

    expect((await op(t, "automation.secret.remove", { automation, name: "MODELS_CATALOG_TOKEN" })).value).toEqual({ automation, name: "MODELS_CATALOG_TOKEN", removed: true })
    expect((await read(t, "automation.secret.list", { automation })).value.secrets.map((s: { name: string }) => s.name)).toEqual(["GOOGLE_APPLICATION_CREDENTIALS_JSON"])
    // Deleting the automation deletes its secrets.
    expect((await op(t, "automation.delete", { automation })).ok).toBe(true)
    await inDO(scheduler, async (_s, state) => {
      expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM automation_secrets WHERE automation = ?", automation).one().n).toBe(0)
    })
  })

  it("another person cannot set, list or reach them", async () => {
    const owner = await token("auto-secret-2")
    await op(owner, "user.ensure", {})
    const a = await op(owner, "automation.create", { name: "s", triggers: [{ type: "manual" }], body: { type: "steps", steps: [{ type: "note", text: "hi" }] } })
    const other = await token("auto-secret-3")
    await op(other, "user.ensure", {})
    expect((await op(other, "automation.secret.set", { automation: a.value.id, name: "X_TOKEN", value: "v" })).ok).toBe(false)
    const refused = await read(other, "automation.secret.list", { automation: a.value.id })
    expect(refused.value, JSON.stringify(refused)).toBeUndefined()
  })
})

describe("a machine step with secrets", () => {
  it("sends them on stdin's first line and never in the command", async () => {
    const calls: Array<{ command: string; stdin: string }> = []
    const port: MachineExec = { exec: async (_m, command, stdin) => (calls.push({ command, stdin: stdin ? new TextDecoder().decode(stdin) : "" }), { ok: true, exitCode: 0, stdout: "ok", stderr: "" }) }
    const step = { type: "machine", machine: "vm_aaaaaaaaaaaaaaaaaaaa", command: "bash scripts/models/run-scout.sh", timeout_seconds: 60 } as const
    await runMachineStep(port, step, { run: "run_bbbbbbbbbbbbbbbbbbbb", index: 0 }, null, { MODELS_CATALOG_TOKEN: TOKEN })
    expect(calls[0]!.command).not.toContain(TOKEN)
    expect(calls[0]!.command).toContain("read -r __cmux_secrets")
    const [line] = calls[0]!.stdin.split("\n")
    expect(atob(line!)).toBe(`MODELS_CATALOG_TOKEN=${TOKEN}\u0000`)
    // With none, the command is the one it always was.
    await runMachineStep(port, step, { run: "run_bbbbbbbbbbbbbbbbbbbb", index: 0 }, null, {})
    expect(calls[1]!.command).toBe(machineStepCommand(step, { run: "run_bbbbbbbbbbbbbbbbbbbb", index: 0 }))
  })
})
