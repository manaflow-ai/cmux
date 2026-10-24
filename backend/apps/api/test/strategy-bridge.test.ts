import { describe, expect, it } from "vitest"
import { StrategyIntegrationBridge, type StrategyHttp } from "../src/integrations/strategy-bridge.ts"

const fake = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })
const harness = (response: Response = fake({ ok: true, id: "result-1", url: "https://example.test/result" })) => {
  const calls: Request[] = []
  const http: StrategyHttp = { request: async (request) => { calls.push(request); return response.clone() } }
  return { calls, bridge: new StrategyIntegrationBridge({ github_api: "https://github.test", linear_api: "https://linear.test", slack_api: "https://slack.test", preview_api: "https://preview.test", cloud_api: "https://cloud.test" }, http) }
}

describe("strategy integration bridge", () => {
  it("maps a GitHub comment and carries idempotency without exposing credentials", async () => {
    const h = harness()
    const result = await h.bridge.run({ provider: "github", action: "github.comment", mutation_id: "github-1234", input: { repo: "manaflow-ai/cmux", issue: "42", body: "preview ready" } }, "github-token-test")
    expect(result.id).toBe("result-1")
    expect(h.calls[0]!.url).toBe("https://github.test/repos/manaflow-ai/cmux/issues/42/comments")
    expect(h.calls[0]!.headers.get("idempotency-key")).toBe("github-1234")
    expect(await h.calls[0]!.text()).not.toContain("github-token-test")
    expect(h.calls[0]!.headers.get("authorization")).toBe("Bearer github-token-test")
  })

  it("normalizes Linear's GraphQL result", async () => {
    const h = harness(fake({ data: { issueCreate: { success: true, issue: { id: "lin-1", identifier: "ENG-1", url: "https://linear.test/ENG-1" } } } }))
    const result = await h.bridge.run({ provider: "linear", action: "linear.issue.create", mutation_id: "linear-1234", input: { team_id: "team-1", title: "Build preview" } }, "linear-token-test")
    expect(result).toMatchObject({ id: "lin-1", url: "https://linear.test/ENG-1" })
    expect(JSON.parse(await h.calls[0]!.text()).variables.input).toEqual({ teamId: "team-1", title: "Build preview" })
  })

  it("covers Slack, Vercel-style preview and cloud attach payloads", async () => {
    const h = harness()
    await h.bridge.run({ provider: "slack", action: "slack.message.post", mutation_id: "slack-1234", input: { channel: "C123", text: "ready" } }, "slack-token-test")
    expect(JSON.parse(await h.calls[0]!.text())).toEqual({ channel: "C123", text: "ready" })
    await h.bridge.run({ provider: "preview", action: "preview.create", mutation_id: "preview-1234", input: { project: "cmux", git_ref: "feat/demo", commit: "abc123" } }, "preview-token-test")
    expect(h.calls[1]!.url).toBe("https://preview.test/v13/deployments")
    const preview = JSON.parse(await h.calls[1]!.text())
    expect(preview.target).toBe("preview")
    await h.bridge.run({ provider: "cloud", action: "cloud.machine.attach", mutation_id: "cloud-1234", input: { machine_id: "m-1", session_id: "s-1" } }, "cloud-token-test")
    expect(h.calls[2]!.url).toBe("https://cloud.test/v1/machines/m-1/attach")
  })

  it("rejects insecure remote endpoints, mismatched actions, and unsafe TTL", async () => {
    expect(() => new StrategyIntegrationBridge({ cloud_api: "http://cloud.example" })).toThrow(/HTTPS/)
    const h = harness()
    await expect(h.bridge.run({ provider: "github", action: "slack.message.post", mutation_id: "mismatch-1", input: {} }, "token-1234")).rejects.toThrow(/mismatch/)
    await expect(h.bridge.run({ provider: "cloud", action: "cloud.machine.create", mutation_id: "ttl-12345", input: { vendor: "gcp", region: "us-central1", sku: "e2-standard-4", ttl_seconds: 30 } }, "token-1234")).rejects.toThrow(/ttl_seconds/)
  })
})
