/// <reference types="vite/client" />
import { createRootRoute, HeadContent, Link, Outlet, Scripts, useNavigate } from "@tanstack/react-router"
import type { ReactNode } from "react"
import { useLocale } from "../lib/approval-strings"
import { useLoad } from "../lib/hooks"
import { read, signOut } from "../lib/server"
import { setSignedIn, useSignedIn } from "../lib/session"
import { TeamsContext } from "../lib/team-api"
import { TeamForbidden, TeamPicker } from "../lib/team-picker"
import { keepTeam, notMemberOf, parseTeamSearch, searchForTeam, type TeamsList } from "../lib/team-scope"
import { teamText } from "../lib/team-strings"

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
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "cmux Cloud (next)" },
      { property: "og:site_name", content: "cmux" },
      { name: "theme-color", content: "#0b1020" }
    ],
    links: [
      { rel: "icon", href: "/favicon.ico", sizes: "32x32" },
      { rel: "icon", type: "image/png", href: "/icon.png" },
      { rel: "apple-touch-icon", href: "/apple-touch-icon.png" }
    ]
  }),
  // ?team=<id> (cx-5xew): the team every page acts in; absent = the personal team.
  validateSearch: parseTeamSearch,
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
  const locale = useLocale()
  const { team } = Route.useSearch()
  const navigate = useNavigate()
  // Read without a team (the personal scope), so the list loads even when the URL's team refuses the caller.
  const teams = useLoad<TeamsList>(signedIn ? "user-teams" : null, async () => {
    const r = await read({ data: { op: "user.teams.list", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`user.teams.list ${r.status}`)
    return r.body.value as unknown as TeamsList
  })
  const list = teams.data
  const pick = (id: string) => void navigate({ to: ".", search: ((prev: Record<string, unknown>) => searchForTeam(prev, list?.teams, id)) as never })
  const personal = list?.teams.find((t) => t.kind === "personal")?.id
  // The server's list is TeamDO-confirmed: a URL team a complete list does not have is refused on every call.
  const refused = signedIn && list && !list.incomplete && notMemberOf(list.teams, team) ? team : undefined
  return (
    <TeamsContext.Provider value={{ list, reload: teams.reload }}>
      <header>
        <strong>cmux Cloud (next)</strong>
        <Link to="/devices" search={keepTeam} activeProps={{ className: "active" }}>
          Devices
        </Link>
        <Link to="/team" search={keepTeam} activeProps={{ className: "active" }}>
          Team
        </Link>
        <Link to="/automations" search={keepTeam} activeProps={{ className: "active" }}>
          Automations
        </Link>
        <Link to="/integrations" search={keepTeam} activeProps={{ className: "active" }}>
          Integrations
        </Link>
        <Link to="/policy" search={keepTeam} activeProps={{ className: "active" }}>
          Policy
        </Link>
        <span style={{ flex: 1 }} />
        {signedIn && list ? <TeamPicker teams={list.teams} selected={team} locale={locale} onSelect={pick} /> : null}
        {signedIn && teams.loading && !list ? <span className="muted">{teamText(locale, "picker.loading")}</span> : null}
        {signedIn ? (
          <button onClick={() => void signOut().then(() => setSignedIn(false))}>Sign out</button>
        ) : signedIn === false ? (
          <Link to="/">Sign in</Link>
        ) : null}
      </header>
      <main>
        {teams.error ? <p className="error">{teamText(locale, "picker.error", { error: teams.error })}</p> : null}
        {list?.incomplete ? <p className="muted">{teamText(locale, "picker.incomplete")}</p> : null}
        {refused ? <TeamForbidden team={refused} locale={locale} onPersonal={() => personal && pick(personal)} /> : <Outlet />}
      </main>
    </TeamsContext.Provider>
  )
}
