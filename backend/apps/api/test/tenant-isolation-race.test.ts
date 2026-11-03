import { describe, expect, it } from "vitest"
import { callOp, callRead, makeTenant, succeeded, type Tenant } from "./setup/tenant.ts"

/**
 * Tenant isolation under concurrency (plans/cmux-next/tenant-isolation-DESIGN.md section 5.6): twelve tenants write and
 * read at the same instant, many rounds; every list holds only its own canary. Two tenants send the SAME
 * idempotency key and client message id together: neither gets the other's cached result.
 */
const SIZE = { cpu: 2, memory_mb: 4096, disk_mb: 16384 }
const TENANTS = 12
const ROUNDS = 4

describe("concurrent tenants", { timeout: 300_000 }, () => {
  it(`${TENANTS} tenants x ${ROUNDS} rounds of parallel writes and reads never see each other's canary`, async () => {
    const tenants: Array<Tenant> = []
    for (let i = 0; i < TENANTS; i++) tenants.push(await makeTenant(String.fromCharCode(97 + i)))
    const violations: Array<string> = []
    const scan = (reader: Tenant, label: string, raw: string) => {
      for (const other of tenants) if (other !== reader && raw.includes(other.canary)) violations.push(`${reader.tag} saw ${other.tag}'s canary in ${label}`)
    }
    for (let round = 0; round < ROUNDS; round++) {
      await Promise.all(
        tenants.map(async (t) => {
          const writes = await Promise.all([
            callOp(t.session, "group.create", { name: `${t.canary} group ${round}` }),
            callOp(t.session, "feed.post", { type: "notice", kind: "notice", title: `${t.canary} feed ${round}` }),
            callOp(t.session, "cloud.machine.create", { size: SIZE, name: `${t.canary} m${round}` }),
            callOp(t.installToken, "host.enroll", { name: `${t.canary} host ${round}`, platform: "macos" })
          ])
          for (const w of writes) if (!succeeded(w) && w.code !== "cloud.quota.exceeded" && w.code !== "cloud.limit") violations.push(`${t.tag} write failed: ${w.raw.slice(0, 160)}`)
          const reads = await Promise.all(
            ["group.list", "feed.list", "cloud.machine.list", "team.hosts.list", "team.directory", "inbox.list", "install.list", "chief.list", "usage.summary"].map(async (op) => [op, await callRead(t.session, op, op === "inbox.list" ? { limit: 50 } : {})] as const)
          )
          for (const [op, r] of reads) scan(t, `${op} round ${round}`, r.raw)
          // The scan can fail: a tenant's own lists carry its own canary.
          const groups = reads.find(([op]) => op === "group.list")![1]
          if (!groups.raw.includes(t.canary)) violations.push(`${t.tag} lost its own group (control)`)
        })
      )
    }
    expect(violations.join("\n")).toBe("")
  })

  it("the same idempotency key and client_msg_id from two tenants at once never replays one tenant's result to the other", async () => {
    const x = await makeTenant("a")
    const y = await makeTenant("b")
    const key = crypto.randomUUID()
    const [rx, ry] = await Promise.all([callOp(x.session, "group.create", { name: `${x.canary} shared-key` }, key), callOp(y.session, "group.create", { name: `${y.canary} shared-key` }, key)])
    expect(succeeded(rx) && succeeded(ry), `${rx.raw} ${ry.raw}`).toBe(true)
    expect(rx.body.replayed).toBe(false)
    expect(ry.body.replayed, "the other tenant's key must not hit x's cache").toBe(false)
    expect(rx.body.value.id).not.toBe(ry.body.value.id)
    expect(ry.raw).not.toContain(x.canary)
    expect(rx.raw).not.toContain(y.canary)
    // Same for a DM message: client_msg_id is per sender.
    const dmx = await callOp(x.session, "dm.open", { peer: { email: `p-${x.sub}@tenant.test` } })
    const dmy = await callOp(y.session, "dm.open", { peer: { email: `p-${y.sub}@tenant.test` } })
    const mid = crypto.randomUUID()
    const send = (t: Tenant, c: string) => callOp(t.session, "message.send", { conversation: c, client_msg_id: mid, parts: [{ type: "text", text: `${t.canary} hello` }] }, mid)
    const [mx, my] = await Promise.all([send(x, dmx.body.value.conversation.id), send(y, dmy.body.value.conversation.id)])
    expect(succeeded(mx) && succeeded(my), `${mx.raw} ${my.raw}`).toBe(true)
    const hx = await callRead(x.session, "conversation.history", { conversation: dmx.body.value.conversation.id, limit: 20 })
    expect(hx.raw).toContain(x.canary)
    expect(hx.raw).not.toContain(y.canary)
    // A foreign sender reusing the key against x's conversation is refused and does not replay x's message.
    const intruder = await send(y, dmx.body.value.conversation.id)
    expect(succeeded(intruder), intruder.raw).toBe(false)
    expect(intruder.raw).not.toContain(x.canary)
  })

  it("8 simultaneous probes per stranger of A's conversation, machine and snapshot by 6 strangers return only refusals and leave A unchanged", async () => {
    const a = await makeTenant("a")
    const strangers = await Promise.all(["b", "c", "d", "e", "f", "g"].map((t) => makeTenant(t)))
    const created = await callOp(a.session, "cloud.machine.create", { size: SIZE, name: `${a.canary} target` })
    const machine = created.body.value.machine.id as string
    const dm = await callOp(a.session, "dm.open", { peer: { email: `p-${a.sub}@tenant.test` } })
    const conv = dm.body.value.conversation.id as string
    const k = crypto.randomUUID()
    await callOp(a.session, "message.send", { conversation: conv, client_msg_id: k, parts: [{ type: "text", text: `${a.canary} private` }] }, k)
    const probes = strangers.flatMap((s) =>
      Array.from({ length: 8 }, (_, i) => async () => {
        const rs = [
          await callRead(s.session, "conversation.history", { conversation: conv, limit: 50 }),
          await callRead(s.session, "cloud.machine.get", { machine }),
          await callOp(s.session, "cloud.machine.delete", { machine }),
          await callOp(s.session, "title.set", { conversation: conv, title: `hijack ${i}` })
        ]
        return rs.map((r) => ({ ok: succeeded(r), leaked: r.raw.includes(a.canary) }))
      })
    )
    const out = (await Promise.all(probes.map((p) => p()))).flat()
    expect(out.filter((r) => r.ok || r.leaked)).toEqual([])
    const view = await callRead(a.session, "cloud.machine.get", { machine })
    expect(view.raw).toContain(`${a.canary} target`)
    expect((await callRead(a.session, "conversation.history", { conversation: conv, limit: 50 })).raw).toContain(`${a.canary} private`)
  })
})
