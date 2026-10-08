import type { Env } from "./env.ts"
import type { UserState } from "./domains/user.ts"

/** Backoff after a failed KRL notice (in memory: a restart retries at once). */
export interface KrlRetry {
  at: number | null
  attempts: number
}

/** When the KRL notices are next due: now while any is pending, after the backoff. */
export const krlDueAt = (state: UserState | undefined, retry: KrlRetry, now: number): number | null =>
  Object.keys(state?.ssh_revoke_pending ?? {}).length > 0 ? Math.max(now, retry.at ?? 0) : null

/**
 * Delivers pending KRL notices for revoked installs to each team's TeamDO, in parallel, and records
 * every team that confirmed (S4; cx-44j.51) through `done` (the system op `install.ssh_revoke_done`
 * with those teams): the notice ends when no team is left, and a retry asks only the teams still
 * missing. TeamDO's side is idempotent, so a retry after a crash is safe; one failing team never
 * holds back the others.
 */
export const deliverKrlNotices = async (env: Env, state: UserState | undefined, retry: KrlRetry, now: number, done: (install: string, at: number, teams: ReadonlyArray<string>) => void): Promise<void> => {
  const pending = Object.entries(state?.ssh_revoke_pending ?? {})
  if (pending.length === 0 || (retry.at !== null && now < retry.at)) return
  let failed = false
  for (const [install, n] of pending) {
    const results = await Promise.allSettled(
      n.teams.map(async (team) => {
        const r = (await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).revokeInstallCerts(team, n.user, install)) as { ok: boolean }
        if (!r.ok) throw new Error("refused")
        return team
      })
    )
    const confirmed = results.flatMap((r) => (r.status === "fulfilled" ? [r.value] : []))
    results.forEach((r, i) => r.status === "rejected" && console.error(JSON.stringify({ msg: "team ssh krl notice failed", install, team: n.teams[i], attempt: retry.attempts + 1, error: String(r.reason) })))
    if (confirmed.length > 0) done(install, n.at, confirmed)
    if (confirmed.length < n.teams.length) failed = true
  }
  if (failed) {
    retry.attempts += 1
    retry.at = now + Math.min(5 * 60_000, 1000 * 2 ** retry.attempts)
  } else {
    retry.attempts = 0
    retry.at = null
  }
}
