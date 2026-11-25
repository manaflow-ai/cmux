#!/usr/bin/env bun
/**
 * GitHub App drift: the events (and permissions) our webhook receivers need against what an App subscribes to.
 *
 *   bun scripts/github-app-drift.ts          the dev manifest (dev-github-app.ts) against RECEIVER_EVENTS; CI runs this
 *                                            through test-node/github-app-drift.test.ts
 *   bun scripts/github-app-drift.ts --live   also a live App's settings (GET /app), signed with the App's key from
 *                                            GITHUB_APP_CLIENT_ID and GITHUB_APP_PRIVATE_KEY in the environment; never
 *                                            printed. Read only: it changes no App setting.
 *
 * Exits 1 on drift and names each missing event or permission (the App settings checkbox to tick).
 */
import { createPrivateKey } from "node:crypto"
import { importPKCS8, SignJWT } from "jose"
import { GITHUB_PUSH_EVENTS } from "../src/integrations/github-push.ts"
import { EVENTS, PERMISSIONS } from "./dev-github-app.ts"

/**
 * Every webhook event a receiver handles, by receiver. A receiver that starts handling an event adds it here, and the
 * manifest test then fails until the App subscribes to it.
 * - cmux-api /v1/hooks/github: live PR-list updates (GITHUB_PUSH_EVENTS), automations and Chief jobs over any event
 *   (workflow_run for CI failed, push, issues, issue_comment).
 * - cmux-platform feed (src/server/github/Feed.ts EVENT_TYPES) and triggers (src/server/triggers/Model.ts), mirrored
 *   here because the platform is another repository; update both together.
 */
export const RECEIVER_EVENTS: Readonly<Record<string, readonly string[]>> = {
  "cmux-api github-push": [...GITHUB_PUSH_EVENTS],
  "cmux-api automations and Chief jobs": ["push", "issues", "issue_comment", "workflow_run"],
  "cmux-platform github feed": [
    "pull_request",
    "pull_request_review",
    "pull_request_review_comment",
    "issue_comment",
    "check_run",
    "check_suite",
    "status",
    "workflow_run",
    "workflow_job",
    "push",
    "merge_group"
  ],
  "cmux-platform triggers": ["pull_request", "pull_request_review", "pull_request_review_comment", "issue_comment", "workflow_run"]
}

/** The App permission each event needs to be delivered (GitHub: "webhook events and payloads"). */
export const EVENT_PERMISSION: Readonly<Record<string, string>> = {
  check_run: "checks",
  check_suite: "checks",
  issue_comment: "issues",
  issues: "issues",
  merge_group: "merge_queues",
  pull_request: "pull_requests",
  pull_request_review: "pull_requests",
  pull_request_review_comment: "pull_requests",
  pull_request_review_thread: "pull_requests",
  push: "contents",
  status: "statuses",
  workflow_job: "actions",
  workflow_run: "actions"
}

export const neededEvents = (): string[] => [...new Set(Object.values(RECEIVER_EVENTS).flat())].sort()

export interface Drift {
  /** Events a receiver handles that the App does not subscribe to. */
  readonly missingEvents: string[]
  /** Permissions those needed events require that the App does not grant. */
  readonly missingPermissions: string[]
}

export const drift = (events: readonly string[], permissions: Readonly<Record<string, string>>): Drift => {
  const needed = neededEvents()
  const have = new Set(events)
  return {
    missingEvents: needed.filter((e) => !have.has(e)),
    missingPermissions: [...new Set(needed.map((e) => EVENT_PERMISSION[e]).filter((p): p is string => !!p && !permissions[p]))].sort()
  }
}

const report = (label: string, d: Drift): boolean => {
  if (d.missingEvents.length === 0 && d.missingPermissions.length === 0) {
    console.log(`${label}: no drift (${neededEvents().length} events)`)
    return true
  }
  for (const e of d.missingEvents) console.log(`${label}: subscribe to event ${e}`)
  for (const p of d.missingPermissions) console.log(`${label}: grant permission ${p}`)
  return false
}

/** GitHub hands out PKCS#1 keys; jose signs with PKCS#8. */
const pkcs8 = (pem: string) => createPrivateKey(pem.replace(/\\n/g, "\n")).export({ type: "pkcs8", format: "pem" }).toString()

const liveApp = async (): Promise<{ slug: string; events: string[]; permissions: Record<string, string> }> => {
  const iss = process.env.GITHUB_APP_CLIENT_ID
  const pem = process.env.GITHUB_APP_PRIVATE_KEY
  if (!iss || !pem) throw new Error("--live needs GITHUB_APP_CLIENT_ID and GITHUB_APP_PRIVATE_KEY in the environment")
  const now = Math.floor(Date.now() / 1000)
  const jwt = await new SignJWT({}).setProtectedHeader({ alg: "RS256" }).setIssuer(iss).setIssuedAt(now - 60).setExpirationTime(now + 540).sign(await importPKCS8(pkcs8(pem), "RS256"))
  const res = await fetch("https://api.github.com/app", { headers: { authorization: `Bearer ${jwt}`, accept: "application/vnd.github+json", "user-agent": "cmux-github-app-drift" } })
  if (!res.ok) throw new Error(`GET /app answered ${res.status}`)
  const app = (await res.json()) as { slug: string; events: string[]; permissions: Record<string, string> }
  return { slug: app.slug, events: app.events ?? [], permissions: app.permissions ?? {} }
}

if (import.meta.main) {
  let ok = report("dev manifest (dev-github-app.ts)", drift(EVENTS, PERMISSIONS))
  if (process.argv.includes("--live")) {
    const app = await liveApp()
    ok = report(`live App ${app.slug}`, drift(app.events, app.permissions)) && ok
  }
  process.exit(ok ? 0 : 1)
}
