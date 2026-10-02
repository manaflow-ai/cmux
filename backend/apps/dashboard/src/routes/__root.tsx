/// <reference types="vite/client" />
import { createRootRoute, HeadContent, Link, Outlet, Scripts } from "@tanstack/react-router"
import type { ReactNode } from "react"
import { signOut } from "../lib/server"
import { setSignedIn, useSignedIn } from "../lib/session"

const css = `
:root { color-scheme: light dark; --fg:#111; --bg:#fafafa; --muted:#666; --line:#ddd; --card:#fff; --accent:#2563eb; --bad:#b91c1c; }
@media (prefers-color-scheme: dark) { :root { --fg:#eee; --bg:#111; --muted:#999; --line:#333; --card:#1a1a1a; --accent:#60a5fa; --bad:#f87171; } }
* { box-sizing: border-box; }
body { margin:0; font: 14px/1.5 ui-sans-serif, system-ui, sans-serif; color:var(--fg); background:var(--bg); }
header { display:flex; gap:16px; align-items:center; padding:12px 20px; border-bottom:1px solid var(--line); }
header a { color:var(--fg); text-decoration:none; } header a.active { color:var(--accent); font-weight:600; }
main { max-width: 960px; margin: 0 auto; padding: 20px 16px; }
table { width:100%; border-collapse: collapse; } th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align: top; }
code, .mono { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12px; }
button { font: inherit; padding: 4px 10px; border:1px solid var(--line); background:var(--card); color:var(--fg); border-radius:6px; cursor:pointer; }
button.danger { color: var(--bad); }
input, select { font: inherit; padding: 6px 8px; border:1px solid var(--line); border-radius:6px; background:var(--card); color:var(--fg); }
.card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:14px; margin: 12px 0; overflow-x:auto; }
.muted { color: var(--muted); } .error { color: var(--bad); }
`

export const Route = createRootRoute({
  head: () => ({
    meta: [{ charSet: "utf-8" }, { name: "viewport", content: "width=device-width, initial-scale=1" }, { title: "cmux Cloud (next)" }]
  }),
  shellComponent: Shell,
  component: Layout
})

function Shell({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
        <style>{css}</style>
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}

function Layout() {
  const signedIn = useSignedIn()
  return (
    <>
      <header>
        <strong>cmux Cloud (next)</strong>
        <Link to="/devices" activeProps={{ className: "active" }}>
          Devices
        </Link>
        <Link to="/team" activeProps={{ className: "active" }}>
          Team
        </Link>
        <Link to="/automations" activeProps={{ className: "active" }}>
          Automations
        </Link>
        <Link to="/integrations" activeProps={{ className: "active" }}>
          Integrations
        </Link>
        <span style={{ flex: 1 }} />
        {signedIn ? (
          <button onClick={() => void signOut().then(() => setSignedIn(false))}>Sign out</button>
        ) : signedIn === false ? (
          <Link to="/">Sign in</Link>
        ) : null}
      </header>
      <main>
        <Outlet />
      </main>
    </>
  )
}
