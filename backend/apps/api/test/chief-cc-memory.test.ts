import { describe, expect, it } from "vitest"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"
import { enabledChief, inDO, replies, send, testEnv, useCcSettings } from "./chief-brain-cc-harness.ts"

/**
 * The memory tools on the Claude Code route (chief-brain-cc/memory-tools.ts): a Cloud Chief's turn machine opens
 * its own memory tree with `chief-memory zoom ID N` and `chief-memory date ID` (POST 127.0.0.1:4018/vm
 * {action: memory_zoom|memory_date}), answered from the conversation brain's memory as the Pi route's zoom and
 * date tools are. A fork of a home Chief reads its copied memory this way (it had no zoom before).
 */
useCcSettings()
const call = async (s: Started, vm: unknown) => {
  const r = await notes(s, { run: s.run, vm })
  return { status: r.status, body: (await r.json().catch(() => null)) as any }
}

describe("Cloud Chief memory tools", () => {
  it("zooms into the view and dates a message from the turn machine, as the Pi route's tools do", async () => {
    const seen: Record<string, any> = {}
    const cloud = fakeCloud(
      () => "ok",
      async (s, n) => {
        if (n !== 2) return
        seen.zoom = await call(s, { action: "memory_zoom", id: 0, n: 1 })
        seen.date = await call(s, { action: "memory_date", id: 0 })
        seen.missing = await call(s, { action: "memory_zoom", id: 99999, n: 1 })
        seen.bad = await call(s, { action: "memory_zoom", id: "x" })
        seen.other = await call(s, { action: "memory_forget" })
      }
    )
    const a = await enabledChief("chief-cc-memory", "cc")
    expect((await send(a.token, a.chief.main_conversation, "m1", "remember the blue lighthouse")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    expect((await send(a.token, a.chief.main_conversation, "m2", "what did I ask first?")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 2)
    const brain = testEnv.CHIEF_BRAIN_DO.get(testEnv.CHIEF_BRAIN_DO.idFromName(`${a.chief.id}/${a.chief.main_conversation}`))
    const want = await inDO(brain, async (b) => ({ zoom: b.memory.zoom(0, 1) as string, date: b.memory.date(0, "UTC") as string }))
    expect(seen.zoom.status).toBe(200)
    expect(seen.zoom.body.text).toBe(want.zoom)
    expect(seen.zoom.body.text).toContain("blue lighthouse")
    expect(seen.date.status).toBe(200)
    expect(seen.date.body.text).toBe(want.date)
    expect(seen.missing.status).toBe(200)
    expect(seen.missing.body.text).toMatch(/^No line/)
    expect(seen.bad.status).toBe(400)
    expect(seen.other.status).toBe(400)
    // The client ships to every turn machine, and the route's prompt points at it.
    const input = cloud.started[1]!.input as any
    expect(input.files[".local/bin/chief-memory"]).toContain("memory_zoom")
    expect(input.system).toContain("chief-memory zoom")
    expect(input.system).not.toContain("zoom and date tools are not available")
  })
})
