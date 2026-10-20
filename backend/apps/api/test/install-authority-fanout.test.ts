import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { InstallAuthorityFanout } from "../src/install-authority-fanout.ts"
import { registerSocketOwner } from "../src/socket-registry.ts"
import { inDO } from "./team-ssh-support.ts"

const A = "a".repeat(64), B = "b".repeat(64), NOW = 1000
const stored = <T>(body: (sql: SqlStorage) => Promise<T>) => {
  const ns = (env as unknown as { USER_DO: DurableObjectNamespace }).USER_DO
  return inDO(ns.get(ns.idFromName(`fanout-${crypto.randomUUID()}`)), async (_instance, state) => body(state.storage.sql))
}
const environment = (run: (name: string) => Promise<void>) => ({ CLOUD_DO: {
  idFromName: (name: string) => name, get: (name: string) => ({ recheckInstallAuthority: () => run(name) })
} }) as unknown as Env
const owner = (sql: SqlStorage, name: string, install = "install") => registerSocketOwner(sql, install, undefined, "CloudDO", name, NOW + 60_000, NOW)

describe("durable install authority fanout", () => {
  it("continues 257 owners in bounded pages across fresh driver instances", async () => {
    const result = await stored(async (sql) => {
      for (let i = 0; i < 257; i++) owner(sql, String(i).padStart(4, "0"))
      const calls: string[] = [], e = environment(async (name) => { calls.push(name) })
      new InstallAuthorityFanout(sql, e).enqueue("install", A)
      const counts: number[] = []
      for (let i = 0; i < 3; i++) { await new InstallAuthorityFanout(sql, e).run("user", NOW); counts.push(calls.length) }
      return { counts, due: new InstallAuthorityFanout(sql, e).nextAt(NOW), registry: sql.exec(`SELECT * FROM socket_owners`).toArray().length }
    })
    expect(result).toEqual({ counts: [128, 256, 257], due: null, registry: 257 })
  })

  it("retains the first unavailable owner and retries without deleting registrations", async () => {
    const result = await stored(async (sql) => {
      for (const name of ["0", "1", "2"]) owner(sql, name)
      const calls: string[] = []; let unavailable = true
      const e = environment(async (name) => { calls.push(name); if (name === "1" && unavailable) throw new Error("offline") })
      const queue = new InstallAuthorityFanout(sql, e); queue.enqueue("install", A)
      await queue.run("user", NOW)
      const due = queue.nextAt(NOW)
      unavailable = false
      await new InstallAuthorityFanout(sql, e).run("user", NOW + 4999)
      const before = [...calls]
      await new InstallAuthorityFanout(sql, e).run("user", NOW + 5000)
      return { due, before, calls, done: queue.nextAt(NOW), registry: sql.exec(`SELECT * FROM socket_owners`).toArray().length }
    })
    expect(result).toEqual({ due: NOW + 5000, before: ["0", "1", "2"], calls: ["0", "1", "2", "1", "2"], done: null, registry: 3 })
  })

  it("an older in-flight page cannot acknowledge a newer incarnation", async () => {
    const result = await stored(async (sql) => {
      owner(sql, "cloud")
      let release!: () => void, calls = 0
      const held = new Promise<void>((resolve) => { release = resolve })
      const e = environment(() => ++calls === 1 ? held : Promise.resolve()), queue = new InstallAuthorityFanout(sql, e)
      queue.enqueue("install", A)
      const pending = queue.run("user", NOW)
      queue.enqueue("install", B); release(); await pending
      const retained = queue.nextAt(NOW)
      await new InstallAuthorityFanout(sql, e).run("user", NOW)
      return { retained, calls, done: queue.nextAt(NOW) }
    })
    expect(result).toEqual({ retained: NOW, calls: 2, done: null })
  })

  it("one unavailable install does not starve another install", async () => {
    const result = await stored(async (sql) => {
      owner(sql, "bad", "a"); owner(sql, "good", "b")
      const calls: string[] = [], e = environment(async (name) => { calls.push(name); if (name === "bad") throw new Error("offline") })
      const queue = new InstallAuthorityFanout(sql, e); queue.enqueue("a", A); queue.enqueue("b", B)
      await queue.run("user", NOW); await queue.run("user", NOW)
      return { calls, due: queue.nextAt(NOW) }
    })
    expect(result).toEqual({ calls: ["bad", "good"], due: NOW + 5000 })
  })
})
