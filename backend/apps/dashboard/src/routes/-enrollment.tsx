import { useState } from "react"
import { useLoad } from "../lib/hooks"
import { mutate, read } from "../lib/server"
import { newKey } from "../lib/session"

interface Token {
  id: string
  label: string
  allowed_domains: Array<string> | null
  expires_at: number | null
  created_at: number
  revoked_at: number | null
  uses: number
}
interface Device {
  install: string
  user: string
  via: "token" | "accept"
  at: number
}

const b64u = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

/**
 * Device enrollment tokens (spec/enterprise.md 5.4). The browser generates the
 * token and sends only its SHA-256; the token is shown once and never reaches
 * the server. Admins only (the list read refuses members).
 */
export function EnrollmentTokens() {
  const [label, setLabel] = useState("")
  const [domains, setDomains] = useState("")
  const [fresh, setFresh] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const loaded = useLoad<{ tokens: Array<Token>; devices: Array<Device> } | null>("enrollment", async () => {
    const r = await read({ data: { op: "team.enrollment_token.list", params: {} } })
    return r.status === 200 ? (r.body.value as unknown as { tokens: Array<Token>; devices: Array<Device> }) : null
  })
  if (loaded.data === null) return null

  const create = async () => {
    const token = `cmxe_${b64u(crypto.getRandomValues(new Uint8Array(32)))}`
    const hash = b64u(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))))
    const allowed = domains.split(",").map((d) => d.trim().toLowerCase()).filter(Boolean)
    const r = await mutate({
      data: { op: "team.enrollment_token.create", params: { label: label || "MDM", token_hash: hash, ...(allowed.length ? { allowed_domains: allowed } : {}) }, idempotency_key: newKey() }
    })
    if (r.body.ok) {
      setFresh(token)
      setLabel("")
      setDomains("")
      setError(null)
      loaded.reload()
    } else setError(`${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}`)
  }

  const revoke = async (id: string) => {
    const r = await mutate({ data: { op: "team.enrollment_token.revoke", params: { token: id }, idempotency_key: newKey() } })
    if (r.body.ok) loaded.reload()
    else setError(`${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? "failed"}`)
  }

  return (
    <>
      <h3>Device enrollment</h3>
      <div className="card">
        <p className="muted">
          Put a token in your MDM profile as <code>EnrollmentToken</code> (domain <code>com.manaflow.cmux</code>). A signed-in member's Mac then makes this team
          its managing team, and the team's device keys apply on it. A token never adds members.
        </p>
        <input placeholder="Label" value={label} onChange={(e) => setLabel(e.target.value)} />{" "}
        <input placeholder="Allowed email domains (optional, comma separated)" value={domains} onChange={(e) => setDomains(e.target.value)} style={{ width: "40%" }} />{" "}
        <button onClick={() => void create()}>Create token</button>
        {fresh ? (
          <p>
            Copy this token now; it is not shown again: <code>{fresh}</code>
          </p>
        ) : null}
        {error ? <p className="error">{error}</p> : null}
        <table>
          <tbody>
            {(loaded.data?.tokens ?? []).map((t) => (
              <tr key={t.id}>
                <td>{t.label}</td>
                <td className="muted">{t.allowed_domains?.join(", ") ?? "any member"}</td>
                <td>{t.uses} uses</td>
                <td>{t.revoked_at ? <span className="muted">revoked</span> : <button className="danger" onClick={() => void revoke(t.id)}>Revoke</button>}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted">{(loaded.data?.devices ?? []).length} managed devices</p>
      </div>
    </>
  )
}
