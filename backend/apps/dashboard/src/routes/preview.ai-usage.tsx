import { createFileRoute } from "@tanstack/react-router"
import { useState } from "react"
import { useLocale } from "../lib/approval-strings"
import { AI_USAGE_STATE_NAMES, AI_USAGE_STATES } from "./-ai-usage-fixtures"
import { AiUsageView, type AiUsageData } from "./-ai-usage-view"

/**
 * The AI usage view's gallery (cx-y79zh.1 S5): every sample state of the view, with sample data only
 * (no sign-in, no Cloud service calls). Edits change the sample in this page. Not served on the
 * production console.
 *   /preview/ai-usage?state=billed-team|billed-over|unbilled-near|unbilled-open|stopped|no-line
 */
export const Route = createFileRoute("/preview/ai-usage")({
  validateSearch: (s: Record<string, unknown>) => ({ state: typeof s.state === "string" ? s.state : undefined }),
  component: Preview
})

const PRODUCTION_HOST = "console.cmux.dev"

function Sample({ state }: { state: string }) {
  const locale = useLocale()
  const [data, setData] = useState<AiUsageData>(AI_USAGE_STATES[state]!.data)
  const actions = {
    setDefault: async (v: number | null) => (setData((d) => ({ ...d, default_usd: v ?? 200, is_default: v === null, members: d.members.map((m) => (m.source === "personal" ? m : { ...m, limit_usd: v ?? 200, source: v === null ? ("default" as const) : ("team" as const) })) })), null),
    setMember: async (user: string, v: number | null) => (setData((d) => ({ ...d, members: d.members.map((m) => (m.user !== user ? m : v === null ? { ...m, limit_usd: d.default_usd, source: d.is_default ? ("default" as const) : ("team" as const) } : { ...m, limit_usd: v, source: "personal" as const })) })), null)
  }
  return <AiUsageView data={data} locale={locale} actions={actions} />
}

function Preview() {
  const { state } = Route.useSearch()
  if (typeof location !== "undefined" && location.hostname === PRODUCTION_HOST) return <p className="muted">Not available here.</p>
  const states = state && AI_USAGE_STATES[state] ? [state] : AI_USAGE_STATE_NAMES
  return (
    <div>
      {states.map((s) => (
        <section key={s} data-state={s} style={{ marginBottom: 48 }}>
          <p className="muted mono">{s}: {AI_USAGE_STATES[s]!.note}</p>
          <Sample state={s} />
        </section>
      ))}
    </div>
  )
}
