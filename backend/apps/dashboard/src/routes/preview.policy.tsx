import { createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { PolicyView, type PolicyVersion, type TeamPolicy } from "./-policy-view"

/**
 * The Team policy page's gallery (RFD 0211 "The org admin"): an admin's editable view and a member's
 * read-only view of one sample policy, sample data only (no sign-in, no Cloud service calls). Saves
 * change the sample in this page. Not served on the production console.
 *   /preview/policy?state=admin|member
 */
export const Route = createFileRoute("/preview/policy")({
  validateSearch: (s: Record<string, unknown>) => ({ state: typeof s.state === "string" ? s.state : undefined }),
  component: Preview
})

const PRODUCTION_HOST = "console.cmux.dev"

const SAMPLE: TeamPolicy = {
  version: 7,
  updated_at: Date.UTC(2026, 10, 28, 11, 40),
  updated_by: "user_admin",
  values: {
    "cloud.providers": { value: ["cmux", "byoc:acme-aws"], mode: "enforced" },
    "cloud.regions": { value: ["us-west", "eu-central"], mode: "enforced" },
    "cloud.egress": { value: { mode: "allowlist", presets: ["anthropic", "github", "npm"], domains: ["artifacts.acme.dev"] }, mode: "enforced" },
    "agents.harnesses": { value: ["claude", "codex"], mode: "default" },
    "agents.models": { value: ["claude-opus-5-5", "claude-sonnet-*"], mode: "enforced" },
    "projection.folders": { value: ["~/work/**"], mode: "enforced" },
    "projection.readOnly": { value: true, mode: "enforced" },
    "sandbox.local": { value: "required", mode: "enforced" },
    "computerUse.allowed": { value: false, mode: "enforced" },
    "sso.enforce": { value: true, mode: "enforced" },
    "retention.transcriptDays": { value: 90, mode: "enforced" }
  }
}

const HISTORY: Array<PolicyVersion> = [
  { version: 7, changed: ["cloud.egress", "agents.models"], actor: "user_admin", at: Date.UTC(2026, 10, 28, 11, 40), reason: "lock down VMs for the audit", rollback_of: null },
  { version: 6, changed: ["sandbox.local"], actor: "user_owner", at: Date.UTC(2026, 10, 27, 9, 5), reason: null, rollback_of: null }
]

function Sample({ admin }: { admin: boolean }) {
  const [policy, setPolicy] = useState(SAMPLE)
  return (
    <PolicyView
      policy={policy}
      history={admin ? HISTORY : null}
      isAdmin={admin}
      onSave={async (changes) => {
        setPolicy((p) => {
          const values = { ...p.values }
          for (const c of changes) if (c.value === null) delete values[c.key]
          else values[c.key] = c.value
          return { ...p, values, version: p.version + 1, updated_at: Date.now(), updated_by: "you" }
        })
        return null
      }}
      onRollback={async () => null}
    />
  )
}

function Preview() {
  const { state } = Route.useSearch()
  if (typeof location !== "undefined" && location.hostname === PRODUCTION_HOST) return <p className="muted">Not available here.</p>
  const states = state === "admin" || state === "member" ? [state] : ["admin", "member"]
  return (
    <div>
      {states.map((s) => (
        <section key={s} data-state={s} style={{ marginBottom: 48 }}>
          <p className="muted mono">{s}</p>
          <Sample admin={s === "admin"} />
        </section>
      ))}
    </div>
  )
}
