import { describe, expect, it, vi } from "vitest"
import { handleProviderHook } from "../src/ingress/provider-hook.ts"

const SECRET = "fanout-secret"
const hmac = async (msg: string) => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  return [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg)))].map((b) => b.toString(16).padStart(2, "0")).join("")
}

describe("provider hook fan-out", () => {
  it("keeps delivering to later teams when one team's ingest throws, and answers non-2xx so GitHub redelivers", async () => {
    const seen: Array<string> = []
    const links = ["t1", "t2", "t3"].map((team) => ({ team, connection: `c-${team}` }))
    const env = {
      GITHUB_WEBHOOK_SECRET: SECRET,
      ACCOUNT_INDEX_DO: { idFromName: (n: string) => n, get: () => ({ list: async () => links }) },
      CONNECTION_DO: {
        idFromName: (n: string) => n,
        get: (team: string) => ({
          ingest: async () => {
            seen.push(team)
            if (team === "t2") throw new Error("boom")
            return { runs: 1 }
          }
        })
      }
    }
    const body = JSON.stringify({ installation: { id: 7 } })
    const request = new Request("https://api.test/v1/hooks/github", {
      method: "POST",
      headers: { "x-hub-signature-256": `sha256=${await hmac(body)}`, "x-github-delivery": "d1", "x-github-event": "push" },
      body
    })
    const spy = vi.spyOn(console, "error").mockImplementation(() => {})
    const res = await handleProviderHook(request, env as any, "github")
    expect(spy).toHaveBeenCalledTimes(1)
    spy.mockRestore()
    expect(seen).toEqual(["t1", "t2", "t3"])
    expect(res.status).toBe(502)
    expect(await res.json()).toMatchObject({ ok: false, code: "ingest.partial_failure", connections: 3, failed: 1, runs: 2 })
  })
})
