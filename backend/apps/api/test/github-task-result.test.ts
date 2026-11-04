import { env } from "cloudflare:workers"
import { describe, expect, it } from "vitest"
import { handleGithubTaskResult } from "../src/integrations/github-task-result-route.ts"

const request = (body: unknown, method = "POST") => new Request("https://api.test/v1/integrations/github/task-result", {
  method,
  headers: { "content-type": "application/json" },
  body: method === "POST" ? JSON.stringify(body) : undefined,
})

describe("GitHub task-result route", () => {
  it("rejects malformed publication intents before authentication or GitHub calls", async () => {
    const response = await handleGithubTaskResult(request({ taskId: "task_short" }), env)
    expect(response.status).toBe(400)
    await expect(response.json()).resolves.toMatchObject({ error: { code: "request.invalid" } })
  })

  it("requires POST", async () => {
    const response = await handleGithubTaskResult(request({}, "GET"), env)
    expect(response.status).toBe(405)
    await expect(response.json()).resolves.toMatchObject({ error: { code: "request.invalid" } })
  })
})
