import { useState, type ReactNode } from "react"
import type { Locale } from "../lib/approval-strings"
import { aiLimitText, usd, type AiLimitTextKey } from "../lib/ai-limit-strings"
import { AI_USAGE_CSS } from "./-ai-usage-css"

/**
 * The console's AI usage view (cx-y79zh.1 S5): the team's usage this period against its included
 * amount and the stop state, each member's spend next to their limit with an inline edit, and the team
 * default. Data is team.ai_limit.get (the Worker), writes are team.ai_limit.set and
 * team.ai_limit.member.set; this component only draws them, so the real page and the preview route
 * (preview.ai-usage.tsx) render the same code. The design is `meter` (Lawrence 2026-10-14): a progress
 * line and member rows with thin bars.
 */
export interface AiUsageLine {
  readonly billed: boolean
  readonly included_usd: number | null
  readonly per_seat: boolean
  readonly seats: number
  readonly spent_usd: number
  readonly period_start: number | null
  readonly period_end: number
  readonly stop_applies: boolean
  readonly stopped: boolean
}
export interface AiUsageMember {
  readonly user: string
  readonly display_name: string
  readonly role: string
  readonly limit_usd: number
  readonly source: "personal" | "team" | "default"
  readonly spent_usd: number
}
export interface AiUsageData {
  readonly default_usd: number
  readonly is_default: boolean
  readonly resets_at: number
  readonly team_usage?: AiUsageLine
  readonly members: ReadonlyArray<AiUsageMember>
}
/** A write; resolves to an error message, or null when it was saved. */
export interface AiUsageActions {
  readonly setDefault: (usd: number | null) => Promise<string | null>
  readonly setMember: (user: string, usd: number | null) => Promise<string | null>
}

type T = (key: AiLimitTextKey, vars?: Record<string, string>) => string
const NEAR = 0.8

const parseUsd = (raw: string): number | null | undefined => {
  const t = raw.trim()
  if (t === "") return null
  const n = Number(t)
  return Number.isFinite(n) && n >= 0 ? n : undefined
}

const dateOf = (locale: Locale, ms: number) => new Date(ms).toLocaleDateString(locale === "ja" ? "ja-JP" : "en-US", { timeZone: "UTC", month: "long", day: "numeric" })

/** The intro sentence and the state of the team line. */
const lineState = (line: AiUsageLine | undefined) => {
  if (!line || line.included_usd === null || line.spent_usd < 0) return { ratio: null as number | null, state: "open" as const }
  const ratio = line.included_usd > 0 ? line.spent_usd / line.included_usd : line.spent_usd > 0 ? 1 : 0
  if (line.stopped) return { ratio, state: "stopped" as const }
  if (ratio > 1) return { ratio, state: line.billed ? ("over" as const) : ("over_free" as const) }
  // "Near" warns of a stop, so only where the stop applies (review P2).
  if (ratio >= NEAR && line.stop_applies) return { ratio, state: "near" as const }
  return { ratio, state: "ok" as const }
}

const Intro = ({ t, locale, data }: { t: T; locale: Locale; data: AiUsageData }) => {
  const line = data.team_usage
  if (!line || line.included_usd === null) return <p className="aiu-intro">{t("usage.intro.open", { date: dateOf(locale, data.resets_at) })}</p>
  const included = usd(locale, line.per_seat ? line.included_usd / Math.max(1, line.seats) : line.included_usd)
  if (!line.billed) return <p className="aiu-intro">{t(line.stop_applies ? "usage.intro.unbilled" : "usage.intro.unbilled_open", { included })}</p>
  return <p className="aiu-intro">{t("usage.intro.billed", { included, per: line.per_seat ? t("usage.per.seat", { seats: String(line.seats) }) : t("usage.per.team") })}</p>
}

/** The thin bar: the part used, capped at the track; `tone` only for real state. */
const Bar = ({ ratio, tone }: { ratio: number; tone: "ok" | "near" | "stopped" | "over" | "over_free" }) => (
  <div className="aiu-bar" role="presentation">
    <div className={`aiu-bar-fill aiu-${tone}`} style={{ width: `${Math.min(1, Math.max(0, ratio)) * 100}%` }} />
  </div>
)

/** An amount with an inline edit: text at rest, a field with Save and Cancel while editing. */
function InlineAmount({ t, label, hint = "usage.input.hint", value, onSave, children }: { t: T; label: string; hint?: AiLimitTextKey; value: number | null; onSave: (v: number | null) => Promise<string | null>; children: (edit: () => void, clear: () => void) => ReactNode }) {
  const [draft, setDraft] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  /** One write: the error stays in view (also for the one-click clear, review P2); a thrown write is an error too. */
  const run = async (v: number | null): Promise<string | null> => {
    setBusy(true)
    try {
      const e = await onSave(v)
      setError(e)
      return e
    } catch (x) {
      const e = String(x)
      setError(e)
      return e
    } finally {
      setBusy(false)
    }
  }
  if (draft === null)
    return (
      <>
        {children(() => setDraft(value === null ? "" : String(value)), () => void run(null))}
        {error ? <span className="aiu-hint aiu-bad" role="alert">{t("error.save", { error })}</span> : null}
      </>
    )
  const parsed = parseUsd(draft)
  const save = async () => {
    if (parsed === undefined || busy) return
    if ((await run(parsed)) === null) setDraft(null)
  }
  return (
    <form className="aiu-edit" onSubmit={(e) => (e.preventDefault(), void save())}>
      <span className="aiu-dollar">$</span>
      <input aria-label={label} autoFocus inputMode="decimal" value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => e.key === "Escape" && setDraft(null)} size={7} />
      <button type="submit" className="aiu-primary" disabled={parsed === undefined || busy}>{t("limit.save")}</button>
      <button type="button" className="aiu-text" onClick={() => setDraft(null)}>{t("limit.cancel")}</button>
      <span className={parsed === undefined || error ? "aiu-hint aiu-bad" : "aiu-hint"}>{error ? t("error.save", { error }) : parsed === undefined ? t("default.invalid") : t(hint)}</span>
    </form>
  )
}

const memberLimitText = (t: T, locale: Locale, m: AiUsageMember) => (m.limit_usd === 0 ? t("usage.member.none") : usd(locale, m.limit_usd))

/** Row actions: shown on hover or keyboard focus only (calm at rest). */
const RowActions = ({ t, m, edit, clear }: { t: T; m: AiUsageMember; edit: () => void; clear: () => void }) => (
  <span className="aiu-actions">
    <button type="button" className="aiu-text" onClick={edit}>{m.source === "personal" ? t("usage.member.edit") : t("usage.member.set")}</button>
    {m.source === "personal" ? <button type="button" className="aiu-text" onClick={clear}>{t("usage.member.clear")}</button> : null}
  </span>
)

const TeamLine = ({ t, locale, line }: { t: T; locale: Locale; line: AiUsageLine | undefined }) => {
  const { ratio, state } = lineState(line)
  if (!line || ratio === null || line.included_usd === null) return null
  const spent = usd(locale, line.spent_usd)
  const included = usd(locale, line.included_usd)
  const left = Math.max(0, line.included_usd - line.spent_usd)
  const over = Math.max(0, line.spent_usd - line.included_usd)
  const end = dateOf(locale, line.period_end)
  const status =
    state === "stopped" ? <p className="aiu-status aiu-bad">{t("usage.stopped", { date: end })}</p>
    : state === "over" ? <p className="aiu-status">{t("usage.over", { over: usd(locale, over) })}</p>
    : state === "over_free" ? <p className="aiu-status">{t("usage.over.unbilled", { over: usd(locale, over) })}</p>
    : state === "near" ? <p className="aiu-status aiu-warn">{t("usage.near")}</p>
    : null
  return (
    <section className="aiu-surface">
      <div className="aiu-line">
        <span className="aiu-figure">{t("usage.used", { spent, included })}</span>
        <span className="aiu-meta">{line.billed ? t("usage.period", { date: end }) : t("usage.resets", { date: end })}</span>
      </div>
      <Bar ratio={ratio} tone={state === "open" ? "ok" : state} />
      {status ?? <p className="aiu-status aiu-muted">{t("usage.left", { left: usd(locale, left) })}</p>}
    </section>
  )
}

const DefaultRow = ({ t, locale, data, actions }: { t: T; locale: Locale; data: AiUsageData; actions: AiUsageActions }) => (
  <InlineAmount t={t} label={t("usage.default.input.label")} hint="usage.default.hint" value={data.is_default ? null : data.default_usd} onSave={actions.setDefault}>
    {(edit, clear) =>
      (
        <div className="aiu-row aiu-row-hover aiu-default" tabIndex={0}>
          <span className="aiu-name">{t("usage.default.row")}</span>
          <span className="aiu-meta">{data.is_default ? t("usage.default.cmux", { amount: usd(locale, data.default_usd) }) : t("usage.default.value", { amount: usd(locale, data.default_usd) })}</span>
          <span className="aiu-actions">
            <button type="button" className="aiu-text" onClick={edit}>{t("usage.default.change")}</button>
            {!data.is_default ? <button type="button" className="aiu-text" onClick={clear}>{t("default.reset")}</button> : null}
          </span>
        </div>
      )
    }
  </InlineAmount>
)

const MeterMember = ({ t, locale, m, actions }: { t: T; locale: Locale; m: AiUsageMember; actions: AiUsageActions }) => {
  const ratio = m.limit_usd > 0 ? m.spent_usd / m.limit_usd : m.spent_usd > 0 ? 1 : 0
  // "At limit" only for a real limit; a 0 limit already reads "No AI".
  const at = m.limit_usd > 0 && m.spent_usd >= m.limit_usd
  return (
    <div className="aiu-row aiu-row-hover aiu-member" tabIndex={0}>
      <span className="aiu-who">
        <span className="aiu-name">{m.display_name}</span>
        <span className="aiu-meta">{m.role} · {m.source === "personal" ? t("usage.member.override") : t("usage.member.inherits")}</span>
      </span>
      <span className="aiu-spend">
        <InlineAmount t={t} label={t("usage.input.label", { member: m.display_name })} value={m.source === "personal" ? m.limit_usd : null} onSave={(v) => actions.setMember(m.user, v)}>
          {(edit, clear) => (
            <>
              <span className="aiu-amounts">
                <span>{t("usage.member.of", { spent: m.spent_usd < 0 ? t("spend.unknown") : usd(locale, m.spent_usd), limit: memberLimitText(t, locale, m) })}</span>
                {at ? <span className="aiu-flag aiu-warn">{t("usage.member.at_limit")}</span> : null}
                <RowActions t={t} m={m} edit={edit} clear={clear} />
              </span>
              <Bar ratio={ratio} tone={at ? "near" : "ok"} />
            </>
          )}
        </InlineAmount>
      </span>
    </div>
  )
}

export function AiUsageView({ data, locale, actions }: { readonly data: AiUsageData; readonly locale: Locale; readonly actions: AiUsageActions }) {
  const t: T = (key, vars) => aiLimitText(locale, key, vars)
  return (
    <div className="aiu">
      <style>{AI_USAGE_CSS}</style>
      <h2 className="aiu-title">{t("usage.title")}</h2>
      <Intro t={t} locale={locale} data={data} />
      <TeamLine t={t} locale={locale} line={data.team_usage} />
      <section className="aiu-surface aiu-list">
        <DefaultRow t={t} locale={locale} data={data} actions={actions} />
        {data.members.map((m) => <MeterMember key={m.user} t={t} locale={locale} m={m} actions={actions} />)}
      </section>
    </div>
  )
}
