import type { Json, OpResponse } from "./server"

/**
 * Dev-only fixture for the App Store pages (CMUX_DASHBOARD_APPS_MOCK=1, never
 * in production): a few listings and an in-memory install set, so the pages
 * render without the API or a sign-in. Not a model of the owners' rules.
 */
const day = 24 * 3600_000
const now = Date.UTC(2026, 9, 2, 12)
const v = (version: string, scopes: Record<string, string>, optional: Record<string, string>, ago: number, yank?: string) => ({
  version,
  tag: `v${version}`,
  engines: { cmux: "^1.0" },
  scopes,
  optional_scopes: optional,
  added_scopes: [],
  published_at: now - ago * day,
  yanked: yank !== undefined,
  yank_reason: yank ?? null
})
const listings = [
  {
    id: "manaflow-ai/github-prs",
    name: "Pull Requests",
    description: "Your open pull requests as a sidebar section, matched to workspaces by branch.",
    publisher: { name: "Manaflow", github_owner: "manaflow-ai", verified: true },
    repository: "https://github.com/manaflow-ai/cmux-app-github-prs",
    categories: ["sidebar", "git"],
    tier: "first-party",
    latest_version: "1.2.0",
    install_count: 1824,
    versions: [
      v("1.2.0", { "workspace:read": "Match pull requests to your workspaces by branch.", "net:api.github.com": "Read your pull requests.", "integration:github": "Use your connected GitHub account without seeing its token." }, { "notification:post": "Notify you when a review is requested." }, 3),
      v("1.1.0", { "workspace:read": "Match pull requests to your workspaces by branch.", "net:api.github.com": "Read your pull requests." }, {}, 30, "Crashed on accounts with no repositories.")
    ]
  },
  {
    id: "acme/todo-list",
    name: "Todo List",
    description: "Your open todos, with a command to start a workspace for one.",
    publisher: { name: "Acme", github_owner: "acme", verified: false },
    repository: "https://github.com/acme/cmux-todo-list",
    categories: ["sidebar"],
    tier: "verified",
    latest_version: "0.4.1",
    install_count: 212,
    versions: [v("0.4.1", { "workspace:write": "Create a workspace for an issue.", "net:todo.example.com": "Read your todos." }, {}, 9)]
  },
  {
    id: "tools/cpu-status",
    name: "CPU Status",
    description: "CPU and memory of the focused workspace's processes in the status bar.",
    publisher: { name: "Tools", github_owner: "tools", verified: true },
    repository: "https://github.com/tools/cmux-cpu-status",
    categories: ["status"],
    tier: "verified",
    latest_version: "2.0.0",
    install_count: 97,
    versions: [v("2.0.0", { "terminal:read": "Read the process list of your terminals." }, {}, 1)]
  }
]
let installs: Array<Record<string, Json>> = [
  { app: "manaflow-ai/github-prs", scope: "user", version: "1.2.0", tier: "first-party", scopes_granted: ["workspace:read", "net:api.github.com", "integration:github"], installed_at: 0, hidden: false, by_default: true },
  { app: "tools/cpu-status", scope: "user", version: "2.0.0", tier: "verified", scopes_granted: ["terminal:read"], installed_at: now - 2 * day, hidden: true }
]
// Phase 1: agents cannot request installs, so no approvals wait.
let approvals: Array<Record<string, Json>> = []

const listingOnly = ({ versions: _v, ...l }: (typeof listings)[number]) => l

export const mockAppsRead = (op: string, params: Record<string, unknown>) => {
  switch (op) {
    case "app.search": {
      const q = String(params.query ?? "").toLowerCase()
      const apps = listings.filter((l) => (!q || `${l.name} ${l.id} ${l.description}`.toLowerCase().includes(q)) && (!params.category || l.categories.includes(String(params.category))) && (!params.tier || l.tier === params.tier))
      return { status: 200, body: { value: { apps: apps.map(listingOnly), next_cursor: null } as unknown as Json } }
    }
    case "app.info": {
      const l = listings.find((x) => x.id === params.app)
      return l ? { status: 200, body: { value: l as unknown as Json } } : { status: 400, body: { code: "selector.not_found", message: `app ${String(params.app)} not found` } }
    }
    case "app.list":
      return { status: 200, body: { value: { installs, approvals, policy: { allowed_tiers: null, allowlist: null, blocklist: [] } } as unknown as Json } }
    default:
      return { status: 400, body: { code: "validation.invalid", message: `unknown read ${op}` } }
  }
}

const ok = (op: string, key: string, value: Json): { status: number; body: OpResponse } => ({
  status: 200,
  body: { ok: true, op, value, transaction: "mock", idempotency_key: key, revision: "1", replayed: false, stream: "user:mock", sequence: 1 }
})

export const mockAppsMutate = (op: string, params: Record<string, unknown>, key: string) => {
  if (op === "app.install") {
    const l = listings.find((x) => x.id === params.app)!
    const install = { app: l.id, scope: "user", version: l.latest_version, tier: l.tier, scopes_granted: params.scopes as Json, installed_at: Date.now(), hidden: false }
    installs = [...installs.filter((i) => i.app !== l.id), install]
    return ok(op, key, { status: "installed", install })
  }
  if (op === "app.hide" || op === "app.unhide") {
    installs = installs.map((i) => (i.app === params.app ? { ...i, hidden: op === "app.hide" } : i))
    return ok(op, key, { app: String(params.app), hidden: op === "app.hide" })
  }
  if (op === "app.remove") {
    installs = installs.filter((i) => i.app !== params.app)
    return ok(op, key, { app: String(params.app), removed: true })
  }
  if (op === "app.approval.decide") {
    const a = approvals.find((x) => x.id === params.approval)
    approvals = approvals.filter((x) => x.id !== params.approval)
    if (a && params.decision === "approve") installs = [...installs, { app: a.app!, scope: a.scope!, version: a.version!, tier: "verified", scopes_granted: a.scopes!, installed_at: Date.now(), hidden: false }]
    return ok(op, key, { approval: a ?? null, install: null })
  }
  return { status: 400, body: { ok: false, op, error: { code: "validation.invalid", message: `mock: ${op}`, retryable: false }, transaction: "", idempotency_key: key, replayed: false, stream: "", sequence: 0 } }
}
