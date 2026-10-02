import { createFileRoute, useNavigate } from "@tanstack/react-router"
import { useState, type FormEvent } from "react"
import { signIn } from "../lib/server"
import { setSignedIn, useSignedIn } from "../lib/session"

export const Route = createFileRoute("/")({ component: SignIn })

function SignIn() {
  const signedIn = useSignedIn()
  const navigate = useNavigate()
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const r = await signIn({ data: { email, password } }).catch((err: unknown) => ({ error: String(err) }))
    setBusy(false)
    if ("error" in r) return setError(r.error)
    setSignedIn(true)
    await navigate({ to: "/devices" })
  }

  return (
    <div className="card" style={{ maxWidth: 380 }}>
      <h2 style={{ marginTop: 0 }}>Sign in</h2>
      {signedIn ? <p className="muted">You are signed in. Open Devices or Team.</p> : null}
      <form onSubmit={submit} style={{ display: "grid", gap: 10 }}>
        <input type="email" placeholder="Email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input type="password" placeholder="Password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
        <button type="submit" disabled={busy}>
          {busy ? "Signing in" : "Sign in"}
        </button>
        {error ? <p className="error">{error}</p> : null}
      </form>
      <p className="muted">Stack Auth, email and password. The session is an HttpOnly cookie.</p>
    </div>
  )
}
