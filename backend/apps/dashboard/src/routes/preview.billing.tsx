import { createFileRoute } from "@tanstack/react-router"
import { useLocale } from "../lib/approval-strings"
import { AUTO_RELOAD_SAMPLE, BILLING_STATE_NAMES, BILLING_STATES } from "./-billing-fixtures"
import { BillingView } from "./-billing-view"

/**
 * The Billing page's gallery (paid-plans-DESIGN.md): every sample state, sample data only (no
 * sign-in, no Cloud service calls). Not served on the production console.
 *   /preview/billing?state=free|pro|over|unknown
 */
export const Route = createFileRoute("/preview/billing")({
  validateSearch: (s: Record<string, unknown>) => ({ state: typeof s.state === "string" ? s.state : undefined }),
  component: Preview
})

const PRODUCTION_HOST = "console.cmux.dev"

function Preview() {
  const { state } = Route.useSearch()
  const locale = useLocale()
  if (typeof location !== "undefined" && location.hostname === PRODUCTION_HOST) return <p className="muted">Not available here.</p>
  const states = state && BILLING_STATES[state] ? [state] : BILLING_STATE_NAMES
  return (
    <div>
      {states.map((s) => (
        <section key={s} data-state={s} style={{ marginBottom: 48 }}>
          <p className="muted mono">{s}: {BILLING_STATES[s]!.note}</p>
          <BillingView data={BILLING_STATES[s]!.data} locale={locale} onTopUp={() => {}} autoReload={AUTO_RELOAD_SAMPLE} onSaveAutoReload={async () => null} />
        </section>
      ))}
    </div>
  )
}
