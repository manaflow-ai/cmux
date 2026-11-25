import { describe, expect, it } from "vitest"
import { claimGitHubDelivery, finishGitHubDelivery, GITHUB_DELIVERY_TTL_MS } from "../src/ingress/github-deliveries.ts"
import { verifyGitHub } from "../src/ingress/providers.ts"
import { hmacHex } from "../src/ingress/verify.ts"
import { signedInWithInstall, worker } from "./cloud-bind-support.ts"
import { inDO, linkGitHub, read, testEnv } from "./github-token-support.ts"

/**
 * GitHub webhooks are processed once per `X-GitHub-Delivery` (security rule 2): GitHub's redelivery of a GUID is a
 * no-op, a signed body replayed under a forged GUID is refused, and a GUID whose attempt failed runs again.
 */

const GUID = "72D3162E-CC78-11E3-81AB-4C9367DC0958"

describe("verifyGitHub: the delivery id is GitHub's GUID, the body hash its check", () => {
  const body = JSON.stringify({ action: "opened", installation: { id: 42 }, pull_request: { number: 7 } })
  const headers = async (delivery: string) => new Headers({ "x-hub-signature-256": `sha256=${await hmacHex("s", body)}`, "x-github-delivery": delivery, "x-github-event": "pull_request" })

  it("keys the delivery by the GUID and keeps the signed body's digest beside it", async () => {
    const v = await verifyGitHub("s", await headers(GUID), body)
    expect(v).toMatchObject({ ok: true, delivery: { delivery_id: `github:${GUID.toLowerCase()}`, event: "pull_request.opened" } })
    const d = (v as { delivery: { digest: string } }).delivery
    expect(d.digest).toMatch(/^sha256:[0-9a-f]{40}$/)
    // The same body under another GUID has the same digest: that is how a header-swapped replay is seen.
    const other = (await verifyGitHub("s", await headers("another-guid"), body)) as { delivery: { digest: string; delivery_id: string } }
    expect([other.delivery.digest, other.delivery.delivery_id]).toEqual([d.digest, "github:another-guid"])
  })

  it("refuses a delivery header that is not a GUID", async () => {
    for (const bad of ["a b", "x".repeat(81), "../x", "g:1"]) expect(await verifyGitHub("s", await headers(bad), body)).toMatchObject({ ok: false, status: 400 })
  })
})

describe("GitHub delivery claims", () => {
  it("new, retry until finished, then duplicate; a known body or GUID with the other half changed is a replay; rows expire after four days", async () => {
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName("delivery-claims"))
    await inDO(stub, async (instance) => {
      const sql = instance.ctx.storage.sql as SqlStorage
      const t = Date.now()
      expect(claimGitHubDelivery(sql, "c1", "g1", "sha256:a", t)).toBe("new")
      // The first attempt failed (no finish): GitHub's redelivery runs again.
      expect(claimGitHubDelivery(sql, "c1", "g1", "sha256:a", t + 1)).toBe("retry")
      finishGitHubDelivery(sql, "c1", "g1")
      expect(claimGitHubDelivery(sql, "c1", "g1", "sha256:a", t + 2)).toBe("duplicate")
      // The same signed body under a new GUID, or a known GUID over another body: the header was forged.
      expect(claimGitHubDelivery(sql, "c1", "g2", "sha256:a", t + 3)).toBe("replayed")
      expect(claimGitHubDelivery(sql, "c1", "g1", "sha256:b", t + 3)).toBe("replayed")
      // Each connection of the team takes the delivery once.
      expect(claimGitHubDelivery(sql, "c2", "g1", "sha256:a", t + 4)).toBe("new")
      // Past four days the row is gone, so the table stays bounded.
      expect(claimGitHubDelivery(sql, "c1", "g3", "sha256:c", t + GITHUB_DELIVERY_TTL_MS + 10)).toBe("new")
      expect(sql.exec<{ n: number }>(`SELECT count(*) AS n FROM github_deliveries`).toArray()[0]!.n).toBe(1)
    })
  })
})

describe("ConnectionDO.ingest: one GitHub delivery, one processing", { timeout: 60_000 }, () => {
  it("forwards a delivery once; its redelivery and a header-swapped replay are duplicates; the hook answers 200 to both", async () => {
    const a = await signedInWithInstall("gh-delivery-once", "cli")
    await linkGitHub(a.session, a.team)
    const connection = (await read(a.session, "integration.list")).body.value.connections.find((c: any) => c.provider === "github").id as string
    const stub = testEnv.CONNECTION_DO.get(testEnv.CONNECTION_DO.idFromName(a.team))
    const payload = { installation: { id: 99 }, ref: "refs/heads/main", repository: { full_name: "acme/web" } }
    const ingest = (guid: string, digest: string) =>
      stub.ingest(a.team, connection, { provider: "github", account: "github:installation:99", delivery_id: `github:${guid}`, event: "push", payload }, digest) as Promise<{ status: string }>
    expect((await ingest("g-1", "sha256:1")).status).toBe("forwarded")
    expect((await ingest("g-1", "sha256:1")).status).toBe("duplicate")
    expect((await ingest("g-2", "sha256:1")).status).toBe("duplicate")
    expect((await ingest("g-3", "sha256:3")).status).toBe("forwarded")

    const body = JSON.stringify({ ...payload, after: crypto.randomUUID() })
    const hook = async (delivery: string) =>
      worker.fetch("https://api.test/v1/hooks/github", { method: "POST", headers: { "x-hub-signature-256": `sha256=${await hmacHex(testEnv.GITHUB_WEBHOOK_SECRET, body)}`, "x-github-delivery": delivery, "x-github-event": "push" }, body })
    const guid = crypto.randomUUID()
    for (const delivery of [guid, guid, crypto.randomUUID()]) {
      const res = await hook(delivery)
      expect(res.status).toBe(200)
    }
  })
})
