import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLoad } from "../lib/hooks"
import { mutate, read, type OpResponse } from "../lib/server"
import { newKey, setSignedIn, useSignedIn } from "../lib/session"

export const Route = createFileRoute("/automations")({ component: Automations })

interface Trigger {
  id: string
  status: "active" | "not_yet_supported"
  next_at: number | null
  spec: { type: string; expr?: string; tz?: string; event?: string; connection?: string; cooldown_seconds?: number }
}
interface Automation {
  id: string
  name: string
  description: string
  enabled: boolean
  version: number
  triggers: Array<Trigger>
  body: { type: "steps"; steps: Array<{ type: string }> } | { type: "agent_prompt"; instructions: string }
  concurrency: { max: number; on_limit: string }
  next_run_at: number | null
  updated_at: number
}
interface Run {
  id: string
  automation: string
  automation_version: number
  trigger: { type: string; scheduled_at?: number; delivery_id?: string }
  state: string
  step: number
  created_at: number
  started_at: number | null
  finished_at: number | null
  error: { code: string; message: string } | null
}

const when = (t: number | null | undefined) => (t ? new Date(t).toLocaleString() : "")
const duration = (r: Run) => (r.started_at && r.finished_at ? `${Math.max(0, Math.round((r.finished_at - r.started_at) / 1000))} s` : "")
const triggerLabel = (t: Trigger) =>
  t.spec.type === "cron" ? `cron ${t.spec.expr} (${t.spec.tz})` : t.spec.type === "event" ? `event ${t.spec.event}` : t.spec.type === "continue" ? `continue, ${t.spec.cooldown_seconds} s cooldown` : t.spec.type

function Automations() {
  const signedIn = useSignedIn()
  const [last, setLast] = useState<OpResponse | null>(null)
  const [hook, setHook] = useState<{ path: string; secret: string } | null>(null)
  const data = useLoad<{ automations: Array<Automation>; runs: Array<Run> }>(signedIn ? "automations" : null, async () => {
    // The personal team (the scheduler's owner) exists once the user exists.
    const e = await mutate({ data: { op: "user.ensure", params: {}, idempotency_key: newKey() } })
    if (e.status === 401) setSignedIn(false)
    if (e.status !== 200) throw new Error(`user.ensure failed: ${e.status}`)
    const [a, r] = await Promise.all([read({ data: { op: "automation.list", params: {} } }), read({ data: { op: "automation.runs.list", params: { limit: 50 } } })])
    if (a.status !== 200 || r.status !== 200) throw new Error(`load failed: ${a.status} ${r.status}`)
    return {
      automations: (a.body.value as unknown as { automations: Array<Automation> }).automations,
      runs: (r.body.value as unknown as { runs: Array<Run> }).runs
    }
  })

  if (signedIn === false)
    return (
      <p>
        <Link to="/">Sign in</Link> to see your automations.
      </p>
    )

  const run = async (op: string, params: Record<string, unknown>) => {
    const r = await mutate({ data: { op, params, idempotency_key: newKey() } })
    if (r.status === 401) return setSignedIn(false)
    setLast(r.body)
    data.reload()
  }
  const showHook = async (automation: string, trigger: string) => {
    const r = await read({ data: { op: "automation.webhook.get", params: { automation, trigger } } })
    if (r.status === 200) setHook(r.body.value as unknown as { path: string; secret: string })
  }
  const names = new Map((data.data?.automations ?? []).map((a) => [a.id, a.name]))

  return (
    <>
      <h2>Automations</h2>
      {data.error ? <p className="error">{data.error}</p> : null}
      <CreateForm onCreate={(params) => void run("automation.create", params)} />
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Automation</th>
              <th>Triggers</th>
              <th>Next run</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {(data.data?.automations ?? []).map((a) => (
              <tr key={a.id}>
                <td>
                  {a.name} {a.enabled ? null : <span className="muted">(disabled)</span>}
                  <br />
                  <code className="muted">
                    {a.id} · v{a.version} · {a.body.type}
                  </code>
                </td>
                <td>
                  {a.triggers.map((t) => (
                    <div key={t.id}>
                      {triggerLabel(t)}
                      {t.status === "not_yet_supported" ? <span className="muted"> (not yet supported)</span> : null}
                      {t.spec.type === "webhook" ? (
                        <>
                          {" "}
                          <button onClick={() => void showHook(a.id, t.id)}>Endpoint</button>
                        </>
                      ) : null}
                    </div>
                  ))}
                </td>
                <td>{when(a.next_run_at)}</td>
                <td style={{ whiteSpace: "nowrap" }}>
                  <button onClick={() => void run("automation.run", { automation: a.id })}>Run now</button>{" "}
                  <button onClick={() => void run("automation.update", { automation: a.id, enabled: !a.enabled })}>{a.enabled ? "Disable" : "Enable"}</button>{" "}
                  <button className="danger" onClick={() => window.confirm(`Delete ${a.name}? Its runs stay in the history.`) && void run("automation.delete", { automation: a.id })}>
                    Delete
                  </button>
                </td>
              </tr>
            ))}
            {data.data && data.data.automations.length === 0 ? (
              <tr>
                <td colSpan={4} className="muted">
                  No automations yet.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
        {data.loading ? <p className="muted">Loading</p> : null}
      </div>
      {hook ? (
        <div className="card mono">
          POST {"<API>"}
          {hook.path}
          <br />
          secret {hook.secret}
          <br />
          <span className="muted">x-cmux-timestamp: unix seconds; x-cmux-signature: v1=hex(HMAC-SHA256(secret, timestamp + "." + body)); optional x-cmux-delivery for dedupe.</span>
        </div>
      ) : null}
      <h3>
        Runs <button onClick={() => data.reload()}>Refresh</button>
      </h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Run</th>
              <th>State</th>
              <th>Trigger</th>
              <th>Created</th>
              <th>Took</th>
            </tr>
          </thead>
          <tbody>
            {(data.data?.runs ?? []).map((r) => (
              <tr key={r.id}>
                <td>
                  {names.get(r.automation) ?? <span className="muted">deleted</span>}
                  <br />
                  <code className="muted">
                    {r.id} · v{r.automation_version}
                  </code>
                </td>
                <td>
                  <span className={r.state === "failed" || r.state === "dead" ? "error" : undefined}>{r.state}</span>
                  {r.error ? (
                    <div className="muted mono">
                      {r.error.code}: {r.error.message}
                    </div>
                  ) : null}
                </td>
                <td>
                  {r.trigger.type}
                  {r.trigger.scheduled_at ? <div className="muted">{when(r.trigger.scheduled_at)}</div> : null}
                  {r.trigger.delivery_id ? <div className="muted mono">{r.trigger.delivery_id}</div> : null}
                </td>
                <td>{when(r.created_at)}</td>
                <td>{duration(r)}</td>
              </tr>
            ))}
            {data.data && data.data.runs.length === 0 ? (
              <tr>
                <td colSpan={5} className="muted">
                  No runs yet.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
      {last ? (
        <div className="card mono">
          {last.ok ? "ok" : <span className="error">rejected: {last.error?.code} {last.error?.message}</span>} · op {last.op} · transaction {last.transaction} · sequence {last.sequence}
          {last.replayed ? " · replayed" : ""}
        </div>
      ) : null}
    </>
  )
}

function CreateForm({ onCreate }: { onCreate: (params: Record<string, unknown>) => void }) {
  const [name, setName] = useState("")
  const [kind, setKind] = useState<"manual" | "cron" | "webhook">("manual")
  const [expr, setExpr] = useState("0 9 * * 1-5")
  const [tz, setTz] = useState(() => (typeof Intl !== "undefined" ? Intl.DateTimeFormat().resolvedOptions().timeZone : "UTC"))
  const [note, setNote] = useState("hello from cmux")
  const [sleep, setSleep] = useState("")
  const submit = () => {
    if (!name.trim()) return
    const triggers: Array<Record<string, unknown>> = [{ type: "manual" }]
    if (kind === "cron") triggers.push({ type: "cron", expr, tz })
    if (kind === "webhook") triggers.push({ type: "webhook" })
    const steps: Array<Record<string, unknown>> = [{ type: "note", text: note }]
    const seconds = Number(sleep)
    if (Number.isInteger(seconds) && seconds > 0) steps.push({ type: "sleep", seconds })
    onCreate({ name: name.trim(), triggers, body: { type: "steps", steps } })
    setName("")
  }
  return (
    <div className="card" style={{ display: "flex", gap: 8, flexWrap: "wrap", alignItems: "center" }}>
      <input placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} />
      <select value={kind} onChange={(e) => setKind(e.target.value as typeof kind)}>
        <option value="manual">Manual only</option>
        <option value="cron">Schedule (cron)</option>
        <option value="webhook">Webhook</option>
      </select>
      {kind === "cron" ? (
        <>
          <input className="mono" style={{ width: 130 }} value={expr} onChange={(e) => setExpr(e.target.value)} />
          <input style={{ width: 170 }} value={tz} onChange={(e) => setTz(e.target.value)} />
        </>
      ) : null}
      <input placeholder="Note step" value={note} onChange={(e) => setNote(e.target.value)} />
      <input placeholder="Sleep seconds" style={{ width: 120 }} value={sleep} onChange={(e) => setSleep(e.target.value)} />
      <button onClick={submit}>Create</button>
      <span className="muted">Agent prompt bodies need the mux and are not runnable yet.</span>
    </div>
  )
}
