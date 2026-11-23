import { createFileRoute } from "@tanstack/react-router"
import { useEffect } from "react"
import { useSignedIn } from "../lib/session"
import { signInHref, takeReturnPath } from "../lib/return-path"

export const Route = createFileRoute("/")({
  // return_to only comes back with a failure (lib/sign-in-flow.ts failedPath); /auth/sign-in validates it again.
  validateSearch: (search: Record<string, unknown>): { signin?: "failed"; return_to?: string } =>
    search.signin === "failed" ? { signin: "failed", ...(typeof search.return_to === "string" && search.return_to.startsWith("/") ? { return_to: search.return_to } : {}) } : {},
  component: SignIn
})

/**
 * Sign in with cmux: the button starts the code + PKCE hand-off with cmux.com (lib/sign-in-flow.ts),
 * which comes back here or to the page that sent the person to sign in.
 */
function SignIn() {
  const signedIn = useSignedIn()
  const { signin, return_to } = Route.useSearch()

  useEffect(() => {
    if (!signedIn) return
    // An invite page sent the person to sign in first; return them to it (fragment included).
    const next = takeReturnPath()
    if (next) window.location.assign(next)
  }, [signedIn])

  return (
    <div className="card" style={{ maxWidth: 380 }}>
      <h2 style={{ marginTop: 0 }}>Sign in</h2>
      {signedIn ? (
        <p className="muted">You are signed in. Open Devices or Team.</p>
      ) : (
        <>
          <a className="button" href={signInHref(return_to ?? "/devices")} role="button">
            {signin === "failed" ? "Try again" : "Sign in with cmux"}
          </a>
          {signin === "failed" ? <p className="error">Sign-in did not finish.</p> : null}
          <p className="muted">You sign in on cmux.com, then come back here.</p>
        </>
      )}
    </div>
  )
}
