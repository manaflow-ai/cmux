import { useLocale } from "../lib/approval-strings"
import { aiLimitText, usd } from "../lib/ai-limit-strings"
import { useLoad } from "../lib/hooks"
import { newKey, setSignedIn } from "../lib/session"
import { useTeamApi } from "../lib/team-api"
import { AiUsageView, type AiUsageLine } from "./-ai-usage-view"

/** team.ai_limit.get (cx-ds09i): members only for team admins and billing members. */
export interface AiLimitMember {
  readonly user: string
  readonly display_name: string
  readonly role: string
  readonly limit_usd: number
  readonly source: "personal" | "team" | "default"
  readonly spent_usd: number
}
export interface AiLimitView {
  readonly team: string
  readonly default_usd: number
  readonly is_default: boolean
  readonly resets_at: number
  readonly me: AiLimitMember
  readonly members?: ReadonlyArray<AiLimitMember>
  /** Beside members only (billing.manage): the team's usage against its included amount (cx-y79zh.1 S5). */
  readonly team_usage?: AiUsageLine
}
interface AuditEntry {
  readonly op: string
  readonly actor: string
  readonly at: number
  readonly detail: { readonly member?: string; readonly before?: number | null; readonly after?: number | null; readonly user?: string; readonly ai_limit_cleared_usd?: number }
}

const LIMIT_OPS = new Set(["team.ai_limit.set", "team.ai_limit.member.set"])

/** The AI limits of the team in the URL, and its recent limit changes (billing.manage readers only). */
export function useAiLimits(team: string | undefined) {
  const { read } = useTeamApi()
  const limits = useLoad<AiLimitView>(team ? `ai-limit:${team}` : null, async () => {
    const r = await read({ data: { op: "team.ai_limit.get", params: {} } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200) throw new Error(`team.ai_limit.get ${r.status}`)
    return r.body.value as unknown as AiLimitView
  })
  const admin = Boolean(limits.data?.members)
  const changes = useLoad<ReadonlyArray<AuditEntry>>(team && admin ? `ai-limit-audit:${team}` : null, async () => {
    const r = await read({ data: { op: "team.audit.list", params: { limit: 100 } } })
    if (r.status !== 200) return []
    const entries = (r.body.value as unknown as { entries: ReadonlyArray<AuditEntry> }).entries
    return entries.filter((e) => LIMIT_OPS.has(e.op) || (e.op === "team.member.remove" && typeof e.detail?.ai_limit_cleared_usd === "number")).slice(0, 10)
  })
  const reload = () => {
    limits.reload()
    changes.reload()
  }
  return { limits, changes, admin, reload }
}

type AiLimits = ReturnType<typeof useAiLimits>

/**
 * A member's name for the change history: the display name, with the user id when the name does not
 * tell members apart (missing, the sign-in service's generic "Member", or shared by two members).
 */
export const memberLabel = (names: ReadonlyMap<string, string>, user: string): string => {
  const name = names.get(user)?.trim()
  if (!name) return user
  const shared = [...names.values()].filter((n) => n.trim() === name).length > 1
  return shared || name === "Member" ? `${name} (${user})` : name
}

/**
 * The "AI usage" section above Members: for admins the usage view (-ai-usage-view.tsx: the team's usage,
 * each member's spend and limit with an inline edit, the team default) and the recent limit changes;
 * for members their own line.
 */
export function AiSpendingSection({ ai, names }: { readonly ai: AiLimits; readonly names: ReadonlyMap<string, string> }) {
  const locale = useLocale()
  const { mutate } = useTeamApi()
  const v = ai.limits.data
  if (ai.limits.error) return <p className="error">{aiLimitText(locale, "error.load", { error: ai.limits.error })}</p>
  if (!v) return null
  const date = new Date(v.resets_at).toLocaleDateString(locale === "ja" ? "ja-JP" : "en-US", { timeZone: "UTC", month: "long", day: "numeric" })
  if (!ai.admin) {
    const me = v.me
    return (
      <>
        <h3>{aiLimitText(locale, "section.title")}</h3>
        <div className="card">
          <p>{aiLimitText(locale, "me.line", { spent: me.spent_usd < 0 ? aiLimitText(locale, "spend.unknown") : usd(locale, me.spent_usd), limit: usd(locale, me.limit_usd), date })}</p>
        </div>
      </>
    )
  }
  const write = async (op: string, params: Record<string, unknown>): Promise<string | null> => {
    const r = await mutate({ data: { op, params, idempotency_key: newKey() } })
    if (r.status === 401) setSignedIn(false)
    ai.reload()
    return r.body.ok ? null : (r.body.error?.message ?? `http ${r.status}`)
  }
  const who = (u: string) => memberLabel(names, u)
  const shown = (x: number | null | undefined) => (typeof x === "number" ? usd(locale, x) : aiLimitText(locale, "value.default"))
  const members = (v.members ?? []).map((m) => ({ ...m, display_name: who(m.user) }))
  return (
    <>
      <AiUsageView
        data={{ default_usd: v.default_usd, is_default: v.is_default, resets_at: v.resets_at, members, ...(v.team_usage ? { team_usage: v.team_usage } : {}) }}
        locale={locale}
        actions={{ setDefault: (value) => write("team.ai_limit.set", { default_usd: value }), setMember: (member, value) => write("team.ai_limit.member.set", { member, limit_usd: value }) }}
      />
      <div className="card">
        <h4>{aiLimitText(locale, "changes.title")}</h4>
        {(ai.changes.data ?? []).length === 0 ? <p className="muted">{aiLimitText(locale, "changes.empty")}</p> : null}
        <ul>
          {(ai.changes.data ?? []).map((c, i) => (
            <li key={`${c.at}-${i}`}>
              {c.op === "team.member.remove"
                ? aiLimitText(locale, "changes.removed", { member: who(c.detail.user ?? ""), amount: usd(locale, c.detail.ai_limit_cleared_usd ?? 0) })
                : aiLimitText(locale, "changes.row", {
                    when: new Date(c.at).toLocaleString(locale === "ja" ? "ja-JP" : "en-US"),
                    who: who(c.actor),
                    what: c.op === "team.ai_limit.set" ? aiLimitText(locale, "changes.team") : aiLimitText(locale, "changes.member", { member: who(c.detail.member ?? "") }),
                    before: shown(c.detail.before),
                    after: shown(c.detail.after)
                  })}
            </li>
          ))}
        </ul>
      </div>
    </>
  )
}
