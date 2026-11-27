import { describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { hubCall } from "../src/chief-brain-cc/hub.ts"
import { mergeTurnFiles, toolPathOk } from "../src/chief-brain-cc/tools.ts"
import { fakeCloud, notes, type Started } from "./chief-brain-cc-fake.ts"
import { enabledChief, replies, send, useCcSettings } from "./chief-brain-cc-harness.ts"

/**
 * The integrations hub on the Claude Code route (chief-brain-cc/hub.ts, RFD 0055 step 2; Leo, 2026-11-23: "linking up
 * things like e.g. stripe so that your agents can refund for you etc."): `chief-hub` in a turn machine reaches
 * cmux-platform's hub over the PLATFORM binding as the Chief of its owner, both from the running turn's brain.
 */
useCcSettings()

const platform = (answer: (body: any) => Response) => {
  const seen: Array<{ url: string; auth: string | null; body: any }> = []
  const fetch = async (input: RequestInfo, init?: RequestInit) => {
    const req = new Request(input, init)
    const body = await req.json()
    seen.push({ url: req.url, auth: req.headers.get("authorization"), body })
    return answer(body)
  }
  return { seen, env: { PLATFORM: { fetch } as unknown as Fetcher, INTERNAL_TOKEN: "test-only-internal" } as Pick<Env, "PLATFORM" | "INTERNAL_TOKEN"> }
}

describe("Cloud Chief hub tools", () => {
  it("asks the platform's hub as the turn's Chief of its owner, never as anyone the model names", async () => {
    const p = platform((b) =>
      Response.json(
        b.name === "hub_call"
          ? { content: [], structuredContent: { status: "approval_required", call: "hcall_000000000000000000000001" } }
          : { content: [], structuredContent: { actions: [{ name: "stripe.refund.create", linked: true }] } },
      ),
    )
    const search = await hubCall(p.env, "user_ann", "chief_1", { action: "hub_search", arguments: { query: "refund" } })
    expect(search).toEqual({ status: 200, json: { result: { actions: [{ name: "stripe.refund.create", linked: true }] } } })
    const call = await hubCall(p.env, "user_ann", "chief_1", {
      action: "hub_call",
      arguments: { action: "stripe.refund.create", args: { charge: "ch_1", amount: 900 }, invocation_id: "refund-ch_1-900" },
      ownerUserId: "user_mallory",
      agent: "chief_evil",
    })
    expect(call.json).toEqual({ result: { status: "approval_required", call: "hcall_000000000000000000000001" } })
    expect(p.seen).toHaveLength(2)
    for (const s of p.seen) {
      expect(s.url).toBe("https://platform/internal/v1/hub/chief/tools")
      expect(s.auth).toBe("Bearer test-only-internal")
      expect(s.body.ownerUserId).toBe("user_ann")
      expect(s.body.agent).toBe("chief_1")
    }
    expect(p.seen[1]!.body).toEqual({
      ownerUserId: "user_ann",
      agent: "chief_1",
      name: "hub_call",
      arguments: { action: "stripe.refund.create", args: { charge: "ch_1", amount: 900 }, invocation_id: "refund-ch_1-900" },
    })
  })

  it("answers a hub refusal as the error, and every gap with a clear status", async () => {
    const refusing = platform(() => Response.json({ content: [], structuredContent: { error: { code: "hub.not_linked" } }, isError: true }))
    expect(await hubCall(refusing.env, "user_ann", "chief_1", { action: "hub_describe", arguments: { action: "x" } })).toEqual({
      status: 200,
      json: { error: { error: { code: "hub.not_linked" } } },
    })
    const off = platform(() => Response.json({ error: { code: "hub.not_found", message: "off" } }, { status: 404 }))
    expect((await hubCall(off.env, "user_ann", "chief_1", { action: "hub_search" })).status).toBe(503)
    const down = platform(() => new Response("boom", { status: 500 }))
    expect((await hubCall(down.env, "user_ann", "chief_1", { action: "hub_search" })).status).toBe(502)
    expect((await hubCall(refusing.env, "user_ann", "chief_1", { action: "hub_link" })).status).toBe(400)
    expect((await hubCall(refusing.env, "user_ann", "chief_1", { action: "hub_call", arguments: [] })).status).toBe(400)
    expect((await hubCall(refusing.env, null, "chief_1", { action: "hub_search" })).status).toBe(409)
    expect((await hubCall({}, "user_ann", "chief_1", { action: "hub_search" })).status).toBe(503)
    expect(refusing.seen).toHaveLength(1)
  })

  it("ships chief-hub to every turn machine, routes hub_* from it, and no Chief tool replaces it", async () => {
    const seen: Record<string, any> = {}
    const call = async (s: Started, vm: unknown) => {
      const r = await notes(s, { run: s.run, vm })
      return { status: r.status, body: (await r.json().catch(() => null)) as any }
    }
    const cloud = fakeCloud(
      () => "ok",
      async (s, n) => {
        if (n === 1) seen.search = await call(s, { action: "hub_search" })
      },
    )
    const a = await enabledChief("chief-cc-hub", "cc")
    expect((await send(a.token, a.chief.main_conversation, "m1", "refund ch_1")).ok).toBe(true)
    await replies(a.token, a.chief.main_conversation, a.chief.id, 1)
    // The test Worker has no PLATFORM binding: the hub_ action reached hubCall, which says so plainly.
    expect(seen.search.status).toBe(503)
    expect(seen.search.body.error).toMatch(/not connected/)
    const input = cloud.started[0]!.input as any
    expect(input.files[".local/bin/chief-hub"]).toContain("hub_call")
    expect(input.system).toContain("chief-hub search|describe|call|status")
    expect(toolPathOk(".local/bin/chief-hub")).toBe(false)
  })

  it("every turn client sends nothing when its request could not be built", () => {
    // A request built in a pipe (`node -e ... | call`) that fails arrives at call() empty; before this, call() sent it
    // anyway and the runner answered something unrelated. Each client's call() now stops first (exit 2).
    const clients = Object.entries(mergeTurnFiles({}, {})).filter(([p]) => p.startsWith(".local/bin/chief-"))
    expect(clients.map(([p]) => p).sort()).toEqual([".local/bin/chief-auto", ".local/bin/chief-github", ".local/bin/chief-hub", ".local/bin/chief-memory", ".local/bin/chief-tools", ".local/bin/chief-wake"])
    for (const [path, text] of clients) {
      expect(text, path).toContain('[ -n "$req" ] || {')
      expect(text, path).toContain("nothing was sent")
      expect(text, path).not.toMatch(/out=\$\(curl /)
    }
  })
})
