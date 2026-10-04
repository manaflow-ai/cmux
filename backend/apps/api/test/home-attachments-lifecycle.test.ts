/** Home attachments: slot and sweep lifecycle under slow uploads and concurrent releases (backend lead re-check of 904f44e909c). */
import { describe, expect, it } from "vitest"

import type { PresignInput } from "../src/r2-presign.ts"
import { attachmentPart, bytesOf, group, intent, op, post, runInDurableObject, sha, signIn, testEnv, upload } from "./home-attachments-support.ts"
import { fireAlarm, quiesce } from "./setup/alarm.ts"

type Inst = { nextWakeAt(s: unknown, now: number): number | null }
const VIDEO = { mime_type: "video/mp4", name: "slow.mp4", width: undefined, height: undefined }
const keyOfPresigned = (uploadUrl: string) => decodeURIComponent(new URL(uploadUrl).pathname).split("/").slice(2).join("/")
const doOf = (id: string) => testEnv.CONVERSATION_DO.get(testEnv.CONVERSATION_DO.idFromName(id))
const slotRows = (stub: unknown) => runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT id, state FROM home_attachment_slots").toArray() as Array<{ id: string; state: string }>)
const usageRows = (user: string) =>
  runInDurableObject(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)), async (_i, state) => (state.storage.sql.exec("SELECT key FROM home_attachment_usage").toArray() as Array<{ key: string }>).map((r) => r.key))
const setExpiry = (stub: unknown, at: number) => runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_slots SET expires_at = ?", at))
const drainAlarms = async (stub: DurableObjectStub, max = 10) => {
  for (let n = 0; n < max; n++) {
    const due = await runInDurableObject(stub, async (i: Inst) => i.nextWakeAt(null, Date.now()))
    if (due === null || due > Date.now()) return
    await fireAlarm(stub)
  }
}

describe("Home attachments: presigned slots outlive their URL by the upload grace (A)", { timeout: 120_000 }, () => {
  it("the presigned URL expires exactly at the slot's stored expires_at", async () => {
    const alice = await signIn("att-life-sign-alice")
    const g = await group(alice)
    const { handleAttachmentIntent } = await import("../src/home-attachments.ts")
    let signed: PresignInput | undefined
    const presign = (i: PresignInput) => ((signed = i), "https://r2.test/bucket/key?X-Amz-Signature=x")
    const req = new Request("https://api.test/v1/home/attachments/intent", {
      method: "POST",
      headers: { authorization: `Bearer ${alice.token}`, "content-type": "application/json" },
      body: JSON.stringify({ conversation: g.id, sha256: "b".repeat(64), byte_count: 40_000_000, ...VIDEO })
    })
    const body = (await (await handleAttachmentIntent(req, testEnv, presign)).json()) as { value: { expires_at: number } }
    expect(signed!.now + signed!.expiresSec * 1000).toBe(body.value.expires_at)
  })

  it("an open presigned slot past its URL expiry keeps its row and charge until the grace ends, so a slow PUT that finishes late is still deleted and refunded", async () => {
    const alice = await signIn("att-life-open-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const big = new Uint8Array(33_000_000).fill(2)
    const r = await intent(alice, g.id, big, VIDEO)
    const key = keyOfPresigned(r.json.value.upload_url)
    // The URL expired a minute ago; the alarm must not reap yet (a PUT that started in time may still be running).
    await setExpiry(stub, Date.now() - 60_000)
    await drainAlarms(stub)
    expect(await slotRows(stub)).toHaveLength(1)
    expect(await usageRows(alice.user)).toHaveLength(1)
    // The slow PUT lands now.
    await testEnv.HOME_ATTACHMENTS.put(key, big, { sha256: sha(big) })
    // After the grace the alarm deletes the object, refunds and removes the row.
    const { UPLOADING_GRACE_MS } = await import("../src/home-attachment-store.ts")
    await setExpiry(stub, Date.now() - UPLOADING_GRACE_MS - 1)
    await drainAlarms(stub)
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
    expect(await slotRows(stub)).toEqual([])
    expect(await usageRows(alice.user)).toEqual([])
  })

  it("a presigned tombstone also waits for the grace, so a late re-PUT is deleted", async () => {
    const alice = await signIn("att-life-tomb-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const declared = new Uint8Array(33_000_000).fill(8)
    const r = await intent(alice, g.id, declared, VIDEO)
    const key = keyOfPresigned(r.json.value.upload_url)
    const other = new Uint8Array(33_000_000).fill(9)
    await testEnv.HOME_ATTACHMENTS.put(key, other, { sha256: sha(other) })
    expect((await post("/v1/home/attachments/commit", alice.token, { conversation: g.id, slot: r.json.value.slot })).json.error.code).toBe("attachment.hash_mismatch")
    expect(await slotRows(stub)).toEqual([{ id: r.json.value.slot, state: "tombstone" }])
    await setExpiry(stub, Date.now() - 60_000)
    await drainAlarms(stub)
    expect(await slotRows(stub)).toHaveLength(1)
    await testEnv.HOME_ATTACHMENTS.put(key, other, { sha256: sha(other) })
    const { UPLOADING_GRACE_MS } = await import("../src/home-attachment-store.ts")
    await setExpiry(stub, Date.now() - UPLOADING_GRACE_MS - 1)
    await drainAlarms(stub)
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
    expect(await slotRows(stub)).toEqual([])
  })
})

describe("Home attachments: a release during a sweep's R2 delete is not lost (B)", { timeout: 120_000 }, () => {
  it("markDirty while the last batch awaits R2 queues another pass, which collects the released record", async () => {
    const alice = await signIn("att-life-redo-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const orphan = bytesOf("collected in the first pass")
    const kept = bytesOf("released during the first pass")
    await upload(alice, g.id, orphan)
    const keptHash = await upload(alice, g.id, kept)
    const sent = await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "m1", parts: [attachmentPart(keptHash, kept)] }, "m1")
    expect(sent.json.ok).toBe(true)
    const later = Date.now() + 25 * 3_600_000
    const store = await import("../src/home-attachment-store.ts")
    const left = await runInDurableObject(stub, async (i: any, state) => {
      // Direct calls with a fake clock: no real-clock runtime alarm may run between them.
      await quiesce(i, state)
      const bucket = i.env.HOME_ATTACHMENTS as R2Bucket
      // During the first pass's R2 delete, the message's reference goes (as a retract does) and the owner marks the sweep dirty.
      let released = false
      const hooked = new Proxy(bucket, {
        get(target, prop) {
          if (prop === "delete")
            return async (keys: string | Array<string>) => {
              if (!released) {
                released = true
                state.storage.sql.exec("DELETE FROM own_rows WHERE tbl = 'attref' AND k >= ? AND k < ?", `${keptHash}:`, `${keptHash};`)
                store.markDirty({ exec: (q: string, ...b: Array<unknown>) => state.storage.sql.exec(q, ...b).toArray() } as never, Date.now())
              }
              return target.delete(keys)
            }
          const v = Reflect.get(target, prop)
          return typeof v === "function" ? v.bind(target) : v
        }
      })
      i.env = { ...i.env, HOME_ATTACHMENTS: hooked }
      expect(await i.collectAttachments(g.id, later)).toBe(1)
      expect(released).toBe(true)
      // The release during the pass leaves a pass due now, not lost until the next release.
      const due = (i as Inst).nextWakeAt(null, later)
      expect(due).not.toBeNull()
      expect(due!).toBeLessThanOrEqual(later)
      await i.collectAttachments(g.id, later)
      return (state.storage.sql.exec("SELECT COUNT(*) AS n FROM home_attachment_objects").toArray()[0] as { n: number }).n
    })
    expect(left).toBe(0)
  })
})

describe("Home attachments: conversation storage deletion catches late presigned PUTs (C)", { timeout: 120_000 }, () => {
  it("after deleteAttachmentStorage, a PUT that lands on an open slot's URL is deleted by a later prefix delete", async () => {
    const alice = await signIn("att-life-purge-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const big = new Uint8Array(33_000_000).fill(1)
    const r = await intent(alice, g.id, big, VIDEO)
    const key = keyOfPresigned(r.json.value.upload_url)
    const conv = stub as unknown as { deleteAttachmentStorage(e: string): Promise<number> }
    await conv.deleteAttachmentStorage(g.id)
    expect(await usageRows(alice.user)).toEqual([])
    // A second delete of the prefix is due once every URL the deletion dropped is past its expiry and the grace.
    const { UPLOADING_GRACE_MS } = await import("../src/home-attachment-store.ts")
    const due = await runInDurableObject(stub, async (i: Inst) => i.nextWakeAt(null, Date.now()))
    expect(due).not.toBeNull()
    expect(due!).toBeGreaterThanOrEqual(r.json.value.expires_at + UPLOADING_GRACE_MS)
    // The slow PUT lands after the deletion; once the delayed delete is due, the alarm removes it.
    await testEnv.HOME_ATTACHMENTS.put(key, big, { sha256: sha(big) })
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_sweep SET purge_at = ?", Date.now() - 1))
    await drainAlarms(stub)
    expect(await testEnv.HOME_ATTACHMENTS.head(key)).toBeNull()
    const after = await runInDurableObject(stub, async (i: Inst) => i.nextWakeAt(null, Date.now()))
    expect(after).toBeNull()
  })
})

describe("Home attachments: the GC releases what it forgets (D)", { timeout: 120_000 }, () => {
  const wake = (stub: unknown) => fireAlarm(stub)
  const storedBytes = (user: string) =>
    runInDurableObject(testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)), async (_i, state) => Number((state.storage.sql.exec("SELECT COALESCE(SUM(bytes), 0) AS b FROM home_attachment_stored").toArray()[0] as { b: number }).b))
  const objects = async (id: string) => (await testEnv.HOME_ATTACHMENTS.list({ prefix: `home/v1/${id}/` })).objects.length
  /** Makes every uploader's stored-bytes release (or `method`) fail inside the ConversationDO until `restore` runs. */
  const failReleases = (stub: unknown, method = "releaseAttachmentStorage") =>
    runInDurableObject(stub, async (i) => {
      const real = i.env.USER_DO as DurableObjectNamespace
      const failing = new Proxy(real, {
        get: (t, p) => {
          if (p !== "get") {
            const v = (t as any)[p]
            return typeof v === "function" ? v.bind(t) : v
          }
          return (id: DurableObjectId) => {
            const stubOf = t.get(id) as any
            return new Proxy(stubOf, { get: (s, m) => (m === method ? async () => Promise.reject(new Error(`${method} unavailable`)) : (...a: Array<unknown>) => s[m as string](...a)) })
          }
        }
      })
      i.env = { ...i.env, USER_DO: failing }
      return () => runInDurableObject(stub, async (j) => void (j.env = { ...j.env, USER_DO: real }))
    })
  const drops = (stub: unknown) =>
    runInDurableObject(stub, async (_i, state) => state.storage.sql.exec("SELECT * FROM home_attachment_drops").toArray() as Array<{ object_key: string; next_attempt_at?: number; attempts?: number; dead?: number }>)

  it("an R2 delete that fails once is retried by the next alarm: the object goes and the stored bytes reach 0", async () => {
    const alice = await signIn("att-gc-r2-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    await upload(alice, g.id, bytesOf("orphan, its delete fails once"))
    expect(await storedBytes(alice.user)).toBeGreaterThan(0)
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_objects SET created_at = ?", Date.now() - 25 * 3_600_000))
    // The first alarm's R2 delete throws (the alarm catches it and backs off).
    await runInDurableObject(stub, async (i, state) => {
      const real = i.env.HOME_ATTACHMENTS as R2Bucket
      let failed = false
      const flaky = new Proxy(real, {
        get: (t, p) => {
          if (p === "delete" && !failed) return async () => ((failed = true), Promise.reject(new Error("r2 unavailable")))
          const v = (t as any)[p]
          return typeof v === "function" ? v.bind(t) : v
        }
      })
      await quiesce(i, state)
      i.env = { ...i.env, HOME_ATTACHMENTS: flaky }
      await i.alarm()
      i.env = { ...i.env, HOME_ATTACHMENTS: real }
    })
    expect(await objects(g.id)).toBe(1)
    // The drop waits for its own backoff; once that has passed, the next alarm retries it.
    const [drop] = await drops(stub)
    expect(drop!.attempts).toBe(1)
    expect(drop!.next_attempt_at!).toBeGreaterThan(Date.now())
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_drops SET next_attempt_at = ?", Date.now() - 1))
    await wake(stub)
    expect(await objects(g.id)).toBe(0)
    expect(await storedBytes(alice.user)).toBe(0)
  })

  it("production order: a message expiring after its upload was covered by an earlier pass is collected in the same alarm as its sweep", async () => {
    const alice = await signIn("att-gc-order-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const body = bytesOf("referenced, then expired")
    const hash = await upload(alice, g.id, body)
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "p1", parts: [attachmentPart(hash, body)] }, "p1")).json.ok).toBe(true)
    const day = 24 * 3_600_000
    // Record 40 days old, message 25 days old, retention 30 days.
    await runInDurableObject(stub, async (i, state) => {
      i.boundEngine.state = { ...i.boundEngine.currentState, retention_days: 30 }
      state.storage.sql.exec("UPDATE home_attachment_objects SET created_at = ?", Date.now() - 40 * day)
      for (const row of state.storage.sql.exec<{ k: string; json: string }>("SELECT k, json FROM own_rows WHERE tbl = 'msg'").toArray())
        state.storage.sql.exec("UPDATE own_rows SET json = ? WHERE tbl = 'msg' AND k = ?", JSON.stringify({ ...JSON.parse(row.json), created_at: new Date(Date.now() - 25 * day).toISOString() }), row.k)
    })
    // Alarm 1: the record is referenced, so the pass keeps it and moves the cutoff past it.
    await wake(stub)
    expect(await objects(g.id)).toBe(1)
    // The message passes its retention window; ONE alarm deletes msg and attref and collects the object.
    await runInDurableObject(stub, async (_i, state) => {
      for (const row of state.storage.sql.exec<{ k: string; json: string }>("SELECT k, json FROM own_rows WHERE tbl = 'msg'").toArray())
        state.storage.sql.exec("UPDATE own_rows SET json = ? WHERE tbl = 'msg' AND k = ?", JSON.stringify({ ...JSON.parse(row.json), created_at: new Date(Date.now() - 31 * day).toISOString() }), row.k)
    })
    // The sweep runs after some I/O in the wake (the clock moves on), so markDirty's Date.now() is later than the wake's captured now.
    await runInDurableObject(stub, async (i, state) => {
      await quiesce(i, state)
      const sweep = i.sweepWake.bind(i)
      i.sweepWake = async (now: number) => {
        await new Promise((r) => setTimeout(r, 5))
        return sweep(now)
      }
      await i.alarm()
      i.sweepWake = sweep
    })
    await runInDurableObject(stub, async (_i, state) => {
      expect(state.storage.sql.exec("SELECT k FROM own_rows WHERE tbl IN ('msg', 'attref')").toArray()).toEqual([])
    })
    expect(await objects(g.id)).toBe(0)
    expect(await storedBytes(alice.user)).toBe(0)
  })

  it("a queued drop whose release fails keeps a real alarm: a later commit never cancels it (no alarm at time 0)", async () => {
    const alice = await signIn("att-gc-alarm-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    await upload(alice, g.id, bytesOf("deleted with its conversation, release fails"))
    const restore = await failReleases(stub)
    const conv = stub as unknown as { deleteAttachmentStorage(e: string): Promise<number> }
    await conv.deleteAttachmentStorage(g.id).catch(() => undefined)
    expect((await drops(stub)).length).toBe(1)
    // A commit afterwards (its outbox and the drop's retry both want the alarm).
    expect((await op(alice.token, "message.send", { conversation: g.id, client_msg_id: "after", parts: [{ type: "text", text: "hi" }] }, "after")).json.ok).toBe(true)
    // The runtime may be firing the alarm the commit set (getAlarm is null from its start until the run sets the next one).
    let alarm: number | null = null
    for (let n = 0; n < 100 && alarm === null; n++) {
      alarm = await runInDurableObject(stub, async (i, state) => {
        await i.alarmIdle
        return state.storage.getAlarm()
      })
      if (alarm === null) await new Promise((r) => setTimeout(r, 20))
    }
    expect(alarm).not.toBeNull()
    // The commit moved the alarm to its outbox (now) or the drop's next attempt, not left a later one.
    expect(alarm!).toBeGreaterThan(0)
    expect(alarm!).toBeLessThanOrEqual(Date.now() + 60_000)
    const [drop] = await drops(stub)
    expect(drop!.next_attempt_at).toBeGreaterThan(0)
    expect(alarm!).toBeLessThanOrEqual(drop!.next_attempt_at!)
    await restore()
  })

  it("a quota refund that fails during storage deletion is not lost: the slot stays until a retry refunds it", async () => {
    const alice = await signIn("att-gc-refund-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    await upload(alice, g.id, bytesOf("stored before the deletion"))
    expect((await intent(alice, g.id, bytesOf("an upload that never finished"))).json.ok).toBe(true)
    const before = await usageRows(alice.user)
    expect((await slotRows(stub)).length).toBe(1)
    const conv = stub as unknown as { deleteAttachmentStorage(e: string): Promise<number> }
    const restore = await failReleases(stub, "refundAttachmentQuota")
    await expect(conv.deleteAttachmentStorage(g.id)).rejects.toThrow()
    await restore()
    // Nothing was forgotten yet: the open slot and its charge are still there for the retry.
    expect((await slotRows(stub)).length).toBe(1)
    expect(await usageRows(alice.user)).toEqual(before)
    await conv.deleteAttachmentStorage(g.id)
    expect((await slotRows(stub)).length).toBe(0)
    expect((await usageRows(alice.user)).length).toBe(before.length - 1)
  })

  it("a failing drop never blocks the unreferenced sweep, and after 10 failed attempts it is dead-lettered (no more retries, no wake)", async () => {
    const alice = await signIn("att-gc-dead-alice")
    const g = await group(alice)
    const stub = doOf(g.id)
    const age = () => runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_objects SET created_at = ?", Date.now() - 25 * 3_600_000))
    await upload(alice, g.id, bytesOf("first orphan, its release keeps failing"))
    await age()
    const restore = await failReleases(stub)
    await wake(stub)
    expect((await drops(stub)).length).toBe(1)
    // A second orphan: the sweep still runs and deletes its object although the first drop keeps failing.
    await upload(alice, g.id, bytesOf("second orphan"))
    await age()
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_drops SET next_attempt_at = ?", Date.now() - 1))
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_sweep SET cutoff = ?, dirty_at = ?", Number.MIN_SAFE_INTEGER, Date.now() - 1))
    await wake(stub)
    expect(await objects(g.id)).toBe(0)
    // The ninth failure leaves one attempt; the tenth dead-letters the drop.
    await runInDurableObject(stub, async (_i, state) => void state.storage.sql.exec("UPDATE home_attachment_drops SET attempts = 9, next_attempt_at = ?", Date.now() - 1))
    await wake(stub)
    const dead = await drops(stub)
    expect(dead.filter((d) => d.dead === 1)).toHaveLength(dead.length)
    expect(dead.every((d) => d.attempts === 10)).toBe(true)
    const wakeAt = await runInDurableObject(stub, async (i) => i.nextWakeAt(i.boundEngine.currentState, Date.now()))
    expect(wakeAt === null || wakeAt > Date.now() + 3_600_000).toBe(true)
    await restore()
  })
})
