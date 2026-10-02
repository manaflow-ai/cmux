import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLoad } from "../lib/hooks"
import { mutate, read, type Json } from "../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"
import { EnrollmentTokens } from "./-enrollment"

export const Route = createFileRoute("/policy")({ component: Policy })

type Mode = "enforced" | "default"
type PolicyValue = { value: Json; mode: Mode }
interface TeamPolicy {
  version: number
  values: Record<string, PolicyValue>
  updated_at: number | null
  updated_by: string | null
}
interface PolicyVersion {
  version: number
  changed: Array<string>
  actor: string | null
  at: number
  reason: string | null
  rollback_of: number | null
}

type Kind = { t: "enum"; values: Array<string> } | { t: "bool" } | { t: "int"; min: number; max: number } | { t: "list" } | { t: "listOrAll" } | { t: "text" }

/**
 * Editor metadata. The record's types and validation live in @cmux/protocol
 * (`policyKeySchemas`); TeamDO validates every change, so this table only
 * picks a control. Keep keys in sync with spec/enterprise.md 4.2.
 */
const GROUPS: Array<{ title: string; keys: Array<[string, Kind, string]> }> = [
  {
    title: "GitHub",
    keys: [
      ["github.repoScope", { t: "enum", values: ["linking_user_repos", "installation"] }, "linking_user_repos"],
      ["github.requireOrgAdmin", { t: "bool" }, "false"],
      ["github.repoAllowList", { t: "list" }, "none (no extra limit)"]
    ]
  },
  { title: "Integrations", keys: [["integrations.allowedProviders", { t: "listOrAll" }, "all"]] },
  {
    title: "MCP",
    keys: [
      ["mcp.server", { t: "enum", values: ["user_choice", "disabled"] }, "user_choice"],
      ["mcp.remoteTransport", { t: "bool" }, "false"]
    ]
  },
  {
    title: "Apps",
    keys: [
      ["apps.install", { t: "enum", values: ["any", "allow_list", "disabled"] }, "any"],
      ["apps.allowedTiers", { t: "list" }, "first-party, verified, community, unverified"],
      ["apps.allowList", { t: "list" }, "none"],
      ["apps.forcedInstalls", { t: "list" }, "none"]
    ]
  },
  {
    title: "Agents and automation",
    keys: [
      ["agents.allowedClasses", { t: "list" }, "mux, agent, run"],
      ["computerUse.allowed", { t: "bool" }, "true"],
      ["browserAutomation.rawCdp", { t: "bool" }, "true"],
      ["cloud.sandboxes", { t: "bool" }, "true"]
    ]
  },
  {
    title: "Telemetry and updates",
    keys: [
      ["telemetry.level", { t: "enum", values: ["full", "crash_only", "off"] }, "full"],
      ["updates.channel", { t: "enum", values: ["stable", "nightly"] }, "stable"],
      ["updates.minimumVersion", { t: "text" }, "none"]
    ]
  },
  {
    title: "Retention (days)",
    keys: [
      ["retention.cuaEventsDays", { t: "int", min: 1, max: 30 }, "30"],
      ["retention.cuaFramesDays", { t: "int", min: 1, max: 7 }, "7"],
      ["retention.transcriptDays", { t: "int", min: 1, max: 3650 }, "none"],
      ["retention.auditDays", { t: "int", min: 365, max: 3650 }, "400"]
    ]
  },
  {
    title: "Sign-in",
    keys: [
      ["sso.enforce", { t: "bool" }, "false"],
      ["sso.enforceForOwners", { t: "bool" }, "false"],
      ["sso.allowGuests", { t: "bool" }, "true"],
      ["sso.sessionMaxAgeHours", { t: "int", min: 1, max: 2160 }, "none"],
      ["sso.idleTimeoutHours", { t: "int", min: 1, max: 2160 }, "none"]
    ]
  }
]

const show = (v: Json): string => (Array.isArray(v) ? v.join(", ") : String(v))

const parse = (kind: Kind, text: string): Json => {
  switch (kind.t) {
    case "bool":
      return text === "true"
    case "int":
      return Number(text)
    case "list":
      return text.split(",").map((s) => s.trim()).filter(Boolean)
    case "listOrAll":
      return text.trim() === "all" ? "all" : text.split(",").map((s) => s.trim()).filter(Boolean)
    default:
      return text
  }
}

/** A staged edit: null clears the key; undefined means unchanged. */
type Draft = Record<string, PolicyValue | null>

function Policy() {
  const signedIn = useSignedIn()
  const [draft, setDraft] = useState<Draft>({})
  const [reason, setReason] = useState("")
  const [status, setStatus] = useState<string | null>(null)
  const loaded = useLoad<{ policy: TeamPolicy; history: Array<PolicyVersion> | null }>(signedIn ? "policy" : null, async () => {
    const r = await read({ data: { op: "team.policy.get", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`team.policy.get failed: ${r.status} (open Devices once to create your personal team)`)
    // History is admins only; members get 403 and see no history section.
    const h = await read({ data: { op: "team.policy.history", params: { limit: 20 } } })
    const value = r.body.value as unknown as { policy: TeamPolicy }
    return { policy: value.policy, history: h.status === 200 ? ((h.body.value as unknown as { versions: Array<PolicyVersion> }).versions ?? []) : null }
  })
  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to see your team policy.
      </p>
    )
  const policy = loaded.data?.policy
  const isAdmin = loaded.data?.history !== null && loaded.data !== undefined
  const effective = (key: string): PolicyValue | undefined => (key in draft ? (draft[key] ?? undefined) : policy?.values[key])

  const save = async () => {
    if (!policy) return
    const changes = Object.entries(draft).map(([key, value]) => ({ key, value }))
    if (changes.length === 0) return
    setStatus("Saving")
    const r = await mutate({
      data: { op: "team.policy.update", params: { changes, expected_version: policy.version, ...(reason ? { reason } : {}) }, idempotency_key: newKey() }
    })
    if (r.body.ok) {
      setDraft({})
      setReason("")
      setStatus(null)
      loaded.reload()
    } else setStatus(`${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}`)
  }

  const rollback = async (version: number) => {
    if (!policy) return
    const r = await mutate({ data: { op: "team.policy.rollback", params: { version, expected_version: policy.version }, idempotency_key: newKey() } })
    if (r.body.ok) loaded.reload()
    else setStatus(`${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}`)
  }

  return (
    <>
      <h2>Team policy</h2>
      <p className="muted">
        Enforced keys are locked for every member and enforced by the owner of each operation. Default keys replace the product default; members can still
        change them. Unset keys stay the member's choice. Devices also honor MDM profiles (domain <code>com.manaflow.cmux</code>), which win over team policy.
        GitHub and integration keys apply team-wide (enforced or default alike) and are enforced by the team's integrations. Agent egress rules live in the
        team network policy.
      </p>
      {loaded.error ? <p className="error">{loaded.error}</p> : null}
      {policy ? (
        <p className="muted">
          Version {policy.version}
          {policy.updated_at ? ` · ${new Date(policy.updated_at).toLocaleString()} by ${policy.updated_by}` : ""}
        </p>
      ) : null}
      {GROUPS.map((g) => (
        <div className="card" key={g.title}>
          <h3 style={{ marginTop: 0 }}>{g.title}</h3>
          <table>
            <tbody>
              {g.keys.map(([key, kind, productDefault]) => {
                const v = effective(key)
                const mode = v?.mode ?? "unset"
                const staged = key in draft
                return (
                  <tr key={key}>
                    <td>
                      <code>{key}</code>
                      {staged ? <span className="muted"> · edited</span> : null}
                    </td>
                    <td>
                      <select
                        disabled={!isAdmin}
                        value={mode}
                        onChange={(e) => {
                          const m = e.target.value
                          setDraft((d) => {
                            if (m === "unset") return { ...d, [key]: null }
                            const base = v?.value ?? parse(kind, kind.t === "enum" ? kind.values[0]! : kind.t === "bool" ? "false" : productDefault === "none" ? "" : productDefault)
                            return { ...d, [key]: { value: base, mode: m as Mode } }
                          })
                        }}
                      >
                        <option value="unset">not set</option>
                        <option value="default">default</option>
                        <option value="enforced">enforced</option>
                      </select>
                    </td>
                    <td>
                      {v ? (
                        <ValueEditor
                          key={JSON.stringify(v.value)}
                          kind={kind}
                          value={v.value}
                          disabled={!isAdmin}
                          onChange={(value) => setDraft((d) => ({ ...d, [key]: { value, mode: v.mode } }))}
                        />
                      ) : (
                        <span className="muted">product default: {productDefault}</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      ))}
      {isAdmin ? (
        <div className="card">
          <input placeholder="Reason (optional)" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: "60%" }} />{" "}
          <button disabled={Object.keys(draft).length === 0} onClick={() => void save()}>
            Save as version {(policy?.version ?? 0) + 1}
          </button>{" "}
          <button disabled={Object.keys(draft).length === 0} onClick={() => setDraft({})}>
            Discard
          </button>
          {status ? <p className={status === "Saving" ? "muted" : "error"}>{status}</p> : null}
        </div>
      ) : (
        <p className="muted">Only team owners and admins can change the policy.</p>
      )}
      {loaded.data?.history && loaded.data.history.length > 0 ? (
        <>
          <h3>History</h3>
          <div className="card">
            <table>
              <tbody>
                {loaded.data.history.map((h) => (
                  <tr key={h.version}>
                    <td>v{h.version}</td>
                    <td>{new Date(h.at).toLocaleString()}</td>
                    <td>
                      <code className="muted">{h.actor}</code>
                    </td>
                    <td>
                      {h.changed.join(", ")}
                      {h.rollback_of !== null ? <span className="muted"> (rollback to v{h.rollback_of})</span> : null}
                      {h.reason ? <div className="muted">{h.reason}</div> : null}
                    </td>
                    <td>{h.version !== policy?.version ? <button onClick={() => void rollback(h.version)}>Roll back</button> : null}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      ) : null}
      {isAdmin ? <EnrollmentTokens /> : null}
      {loaded.loading ? <p className="muted">Loading</p> : null}
    </>
  )
}

function ValueEditor({ kind, value, disabled, onChange }: { kind: Kind; value: Json; disabled: boolean; onChange: (v: Json) => void }) {
  if (kind.t === "enum")
    return (
      <select disabled={disabled} value={String(value)} onChange={(e) => onChange(e.target.value)}>
        {kind.values.map((v) => (
          <option key={v} value={v}>
            {v}
          </option>
        ))}
      </select>
    )
  if (kind.t === "bool")
    return (
      <select disabled={disabled} value={String(value)} onChange={(e) => onChange(e.target.value === "true")}>
        <option value="true">true</option>
        <option value="false">false</option>
      </select>
    )
  if (kind.t === "int")
    return <input type="number" min={kind.min} max={kind.max} disabled={disabled} value={Number(value)} onChange={(e) => onChange(parse(kind, e.target.value))} />
  return <input disabled={disabled} defaultValue={show(value)} onBlur={(e) => onChange(parse(kind, e.target.value))} style={{ width: "100%" }} />
}
