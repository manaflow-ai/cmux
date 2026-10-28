import { createFileRoute, Link } from "@tanstack/react-router"
import { useState } from "react"
import { useLocale } from "../lib/approval-strings"
import type { BillingSummary } from "../lib/billing-model"
import { billingText } from "../lib/billing-strings"
import { useLoad } from "../lib/hooks"
import { billingSummary, creditsTopup } from "../lib/server"
import { setSignedIn, useSignedIn } from "../lib/session"
import { useTeamApi } from "../lib/team-api"
import { BillingView } from "./-billing-view"

/** Billing (paid-plans-DESIGN.md §3): the plan, AI usage, cmux credits and upgrades of the team in the URL. */
export const Route = createFileRoute("/billing")({ component: Billing })

function Billing() {
  const signedIn = useSignedIn()
  const locale = useLocale()
  const { team } = useTeamApi()
  const [topUpError, setTopUpError] = useState<string | null>(null)
  const summary = useLoad<BillingSummary>(signedIn ? `billing:${team ?? "personal"}` : null, async () => {
    const r = await billingSummary({ data: { team } })
    if (r.status === 401) setSignedIn(false)
    if (r.status !== 200 || !r.body.ok) throw new Error(r.body.error?.message ?? `billing ${r.status}`)
    return r.body.value as unknown as BillingSummary
  })
  if (signedIn === false) return <p><Link to="/">{billingText(locale, "signin")}</Link></p>
  const topUp = async (usd: number) => {
    setTopUpError(null)
    const r = await creditsTopup({ data: { usd, team } })
    if (r.status === 200 && r.body.ok && r.body.value?.url) window.location.assign(r.body.value.url)
    else setTopUpError(r.body.error?.message ?? String(r.status))
  }
  return (
    <>
      <h2>{billingText(locale, "title")}</h2>
      {summary.error ? <p className="error">{billingText(locale, "error.load", { error: summary.error })}</p> : null}
      {summary.data ? <BillingView data={summary.data} locale={locale} onTopUp={(a) => void topUp(a)} topUpError={topUpError} /> : null}
    </>
  )
}
