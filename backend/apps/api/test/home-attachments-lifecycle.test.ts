/** Home attachments: slot and sweep lifecycle under slow uploads and concurrent releases (backend lead re-check of 904f44e909c). */
import { describe, expect, it } from "vitest"
import { runDurableObjectAlarm } from "cloudflare:test"
import type { PresignInput } from "../src/r2-presign.ts"
import { bytesOf, group, intent, post, runInDurableObject, sha, signIn, testEnv } from "./home-attachments-support.ts"

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
    await runDurableObjectAlarm(stub)
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
