import { describe, expect, it } from "vitest"
import { drift, EVENT_PERMISSION, neededEvents } from "../scripts/github-app-drift.ts"
import { EVENTS, PERMISSIONS } from "../scripts/dev-github-app.ts"

/** CI's GitHub App drift check: the manifest subscribes to every event a receiver handles, with the permission it needs. */
describe("GitHub App drift", () => {
  it("the dev manifest subscribes to every event our receivers handle and grants each one's permission", () => {
    expect(drift(EVENTS, PERMISSIONS)).toEqual({ missingEvents: [], missingPermissions: [] })
  })

  it("names each event a receiver needs, and knows the permission of each", () => {
    for (const e of ["workflow_run", "workflow_job", "pull_request_review_comment", "merge_group", "pull_request", "check_run"]) expect(neededEvents()).toContain(e)
    for (const e of neededEvents()) expect(EVENT_PERMISSION, e).toHaveProperty(e)
  })

  it("reports an App that misses events or permissions", () => {
    const staging = ["check_run", "check_suite", "issue_comment", "issues", "pull_request", "pull_request_review", "pull_request_review_thread", "push", "status"]
    expect(drift(staging, { checks: "read", issues: "write", pull_requests: "write", contents: "read", statuses: "read" })).toEqual({
      missingEvents: ["merge_group", "pull_request_review_comment", "workflow_job", "workflow_run"],
      missingPermissions: ["actions", "merge_queues"]
    })
  })
})
