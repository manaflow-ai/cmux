import { useState, type ReactNode } from "react"
import type { Json } from "../lib/server"

export type Mode = "enforced" | "default"
export type PolicyValue = { value: Json; mode: Mode }
export interface TeamPolicy {
  version: number
  values: Record<string, PolicyValue>
  updated_at: number | null
  updated_by: string | null
}
export interface PolicyVersion {
  version: number
  changed: Array<string>
  actor: string | null
  at: number
  reason: string | null
  rollback_of: number | null
}

export type Kind =
  | { t: "enum"; values: Array<string> }
  | { t: "bool" }
  | { t: "int"; min: number; max: number }
  | { t: "list" }
  | { t: "listOrAll" }
  | { t: "listOrNone" }
  | { t: "text" }
  | { t: "egress" }

/** Same ids as EGRESS_PRESET_IDS in @cmux/protocol policy.ts (TeamDO validates every change). */
export const EGRESS_PRESETS = ["anthropic", "openai", "openrouter", "opencode", "github", "npm", "pypi", "rust"] as const

export interface PolicyGroup {
  readonly title: string
  /**
   * RFD 0211 lockdown keys: team-scoped allowlists and switches that bind in either mode. A member's setting or a
   * chat's own ask can only narrow them (protocol policy.ts), so the page says so on the group and on each row.
   */
  readonly tightenOnly?: boolean
  readonly keys: Array<[string, Kind, string]>
}

/**
 * Editor metadata. The record's types and validation live in @cmux/protocol
 * (`policyKeySchemas`); TeamDO validates every change, so this table only
 * picks a control. Keep keys in sync with spec/enterprise.md 4.2.
 */
export const GROUPS: Array<PolicyGroup> = [
  {
    title: "Cloud and agent lockdown",
    tightenOnly: true,
    keys: [
      ["cloud.providers", { t: "list" }, "any cloud (cmux or byoc:<account>)"],
      ["cloud.regions", { t: "list" }, "any region"],
      ["cloud.egress", { t: "egress" }, "full internet"],
      ["agents.harnesses", { t: "list" }, "any harness"],
      ["agents.models", { t: "list" }, "any model (a trailing * matches a family)"],
      ["projection.folders", { t: "list" }, "any folder (globs start with ~ or /)"],
      ["projection.readOnly", { t: "bool" }, "false"],
      ["projection.syncBack", { t: "bool" }, "true"],
      ["sandbox.local", { t: "enum", values: ["on", "required"] }, "on"]
    ]
  },
  {
    title: "GitHub",
    keys: [
      ["github.repoScope", { t: "enum", values: ["linking_user_repos", "installation"] }, "linking_user_repos"],
      ["github.requireOrgAdmin", { t: "bool" }, "false"],
      ["github.repoAllowList", { t: "listOrNone" }, "no extra limit (type none to deny every repository)"]
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

/** The first value a key gets when an admin sets it: the product default where it is a value, else an empty allowlist. */
const seed = (kind: Kind, productDefault: string): Json => {
  switch (kind.t) {
    case "enum":
      return kind.values.includes(productDefault) ? productDefault : kind.values[0]!
    case "bool":
      return productDefault === "true"
    case "egress":
      return { mode: "full" }
    case "list":
      return []
    default:
      return parse(kind, productDefault === "none" ? "" : productDefault)
  }
}

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
    case "listOrNone":
      return text.trim() === "none" ? "none" : text.split(",").map((s) => s.trim()).filter(Boolean)
    default:
      return text
  }
}

const TIGHTEN_ONLY_NOTE =
  "Tighten-only. These keys bind whether you set them as default or enforced: a member's setting or a chat's own ask can only narrow them, never widen them. An unset key adds no limit. The platform checks them when a Cloud machine is created and the app checks them when a local chat starts."

/** A staged edit: null clears the key; undefined means unchanged. */
type Draft = Record<string, PolicyValue | null>

export interface PolicyViewProps {
  readonly policy: TeamPolicy | undefined
  /** null for members: history is admins only, and members see the policy read-only. */
  readonly history: Array<PolicyVersion> | null
  readonly isAdmin: boolean
  /** Resolves to an error line, or null once saved. */
  readonly onSave: (changes: Array<{ key: string; value: PolicyValue | null }>, reason: string) => Promise<string | null>
  readonly onRollback: (version: number) => Promise<string | null>
  readonly children?: ReactNode
}

export function PolicyView({ policy, history, isAdmin, onSave, onRollback, children }: PolicyViewProps) {
  const [draft, setDraft] = useState<Draft>({})
  const [reason, setReason] = useState("")
  const [status, setStatus] = useState<string | null>(null)
  const effective = (key: string): PolicyValue | undefined => (key in draft ? (draft[key] ?? undefined) : policy?.values[key])

  const save = async () => {
    if (!policy) return
    const changes = Object.entries(draft).map(([key, value]) => ({ key, value }))
    if (changes.length === 0) return
    setStatus("Saving")
    const error = await onSave(changes, reason)
    if (error === null) {
      setDraft({})
      setReason("")
      setStatus(null)
    } else setStatus(error)
  }

  const rollback = async (version: number) => {
    const error = await onRollback(version)
    if (error !== null) setStatus(error)
  }

  return (
    <>
      <h2>Team policy</h2>
      <p className="muted">
        Enforced keys are locked for every member and enforced by the owner of each operation. Default keys replace the product default; members can still
        change them. Unset keys stay the member's choice. Devices also honor MDM profiles (domain <code>com.manaflow.cmux</code>), which win over team policy.
        GitHub and integration keys apply team-wide (enforced or default alike) and are enforced by the team's integrations. The lockdown keys (clouds,
        regions, egress, harnesses, models, projection, local sandbox) are tighten-only: they bind in either mode. Per-agent egress rules live in the team
        network policy.
      </p>
      {!isAdmin ? (
        <p className="card" role="note" data-testid="policy-read-only">
          <strong>Read-only.</strong> Only team owners and admins can change the policy. You see what applies to you.
        </p>
      ) : null}
      {policy ? (
        <p className="muted">
          Version {policy.version}
          {policy.updated_at ? ` · ${new Date(policy.updated_at).toLocaleString()} by ${policy.updated_by}` : ""}
        </p>
      ) : null}
      {GROUPS.map((g) => (
        <div className="card" key={g.title}>
          <h3 style={{ marginTop: 0 }}>
            {g.title}
            {g.tightenOnly ? <span style={BADGE}>tighten-only</span> : null}
          </h3>
          {g.tightenOnly ? (
            <p className="muted" data-testid="policy-tighten-only">
              {TIGHTEN_ONLY_NOTE}
            </p>
          ) : null}
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
                      {g.tightenOnly ? <span style={BADGE} title="A member or a chat can only narrow this">tighten-only</span> : null}
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
                            const base = v?.value ?? seed(kind, productDefault)
                            return { ...d, [key]: { value: base, mode: m as Mode } }
                          })
                        }}
                      >
                        <option value="unset">not set</option>
                        <option value="default">{g.tightenOnly ? "default (binds)" : "default"}</option>
                        <option value="enforced">{g.tightenOnly ? "enforced (binds)" : "enforced"}</option>
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
      ) : null}
      {history && history.length > 0 ? (
        <>
          <h3>History</h3>
          <div className="card">
            <table>
              <tbody>
                {history.map((h) => (
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
      {children}
    </>
  )
}

const BADGE = {
  marginLeft: 8,
  padding: "1px 6px",
  borderRadius: 4,
  fontSize: "0.75em",
  fontWeight: 500,
  border: "1px solid currentColor",
  opacity: 0.75,
  verticalAlign: "middle",
  whiteSpace: "nowrap"
} as const

type Egress = { mode: "full" | "allowlist" | "none"; presets?: Array<string>; domains?: Array<string> }

const asEgress = (v: Json): Egress => {
  if (v && typeof v === "object" && !Array.isArray(v) && typeof (v as Record<string, Json>).mode === "string") return v as unknown as Egress
  return { mode: "full" }
}

/** cloud.egress: full, an allowlist of presets and exact DNS names, or none. */
function EgressEditor({ value, disabled, onChange }: { value: Json; disabled: boolean; onChange: (v: Json) => void }) {
  const e = asEgress(value)
  const emit = (next: Egress) => {
    const out: Record<string, Json> = { mode: next.mode }
    if (next.mode === "allowlist") {
      out.presets = next.presets ?? []
      out.domains = next.domains ?? []
    }
    onChange(out)
  }
  return (
    <div>
      <select disabled={disabled} value={e.mode} onChange={(ev) => emit({ ...e, mode: ev.target.value as Egress["mode"] })}>
        <option value="full">full internet</option>
        <option value="allowlist">allowlist</option>
        <option value="none">no internet</option>
      </select>
      {e.mode === "allowlist" ? (
        <div style={{ marginTop: 6 }}>
          {EGRESS_PRESETS.map((p) => (
            <label key={p} style={{ marginRight: 10, whiteSpace: "nowrap" }}>
              <input
                type="checkbox"
                disabled={disabled}
                checked={(e.presets ?? []).includes(p)}
                onChange={(ev) => emit({ ...e, presets: ev.target.checked ? [...(e.presets ?? []), p] : (e.presets ?? []).filter((x) => x !== p) })}
              />{" "}
              {p}
            </label>
          ))}
          <input
            disabled={disabled}
            placeholder="exact DNS names, comma separated (api.example.com)"
            defaultValue={(e.domains ?? []).join(", ")}
            onBlur={(ev) => emit({ ...e, domains: ev.target.value.split(",").map((s) => s.trim()).filter(Boolean) })}
            style={{ width: "100%", marginTop: 6 }}
          />
        </div>
      ) : null}
    </div>
  )
}

export function ValueEditor({ kind, value, disabled, onChange }: { kind: Kind; value: Json; disabled: boolean; onChange: (v: Json) => void }) {
  if (kind.t === "egress") return <EgressEditor value={value} disabled={disabled} onChange={onChange} />
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
