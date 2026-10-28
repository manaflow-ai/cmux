import type { Locale } from "../lib/approval-strings"
import { billingModel, type BillingSummary } from "../lib/billing-model"
import { billingText, usd, type BillingTextKey } from "../lib/billing-strings"

const KINDS: ReadonlySet<string> = new Set(["topup", "grant", "charge", "expired", "correction", "opening"])

/** The Billing page body (paid-plans-DESIGN.md §3): plan, usage, credits, upgrade offers. Data in, actions out. */
export function BillingView({ data, locale, onTopUp, topUpError }: { data: BillingSummary; locale: Locale; onTopUp: (usd: number) => void; topUpError?: string | null }) {
  const t = (key: BillingTextKey, vars?: Record<string, string>) => billingText(locale, key, vars)
  const m = billingModel(data)
  const date = (at: number) => new Intl.DateTimeFormat(locale, { dateStyle: "medium" }).format(at)
  const offersBlock = m.offers.length > 0 ? (
        <div className="card">
          <h3 style={{ margin: "0 0 8px" }}>{t("offers.title")}</h3>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(220px, 1fr))", gap: 12 }}>
            {m.offers.map((o) => (
              <div key={o.id} className="card" style={{ margin: 0, borderColor: o.recommended ? "var(--accent)" : undefined }} data-offer={o.id}>
                {o.recommended ? <p className="muted" style={{ margin: 0, color: "var(--accent)" }}>{t("offers.recommended")}</p> : null}
                <p style={{ fontSize: 18, margin: "4px 0" }}><strong>{o.name}</strong></p>
                <p className="muted" style={{ margin: "0 0 10px" }}>{t("offers.month", { price: usd(locale, o.usd) })}</p>
                <a href={o.href} target="_blank" rel="noreferrer"><button style={o.recommended ? { background: "var(--accent)", color: "#fff", borderColor: "var(--accent)" } : undefined}>{t("offers.choose", { plan: o.name })}</button></a>
              </div>
            ))}
          </div>
          <p className="muted" style={{ marginBottom: 0 }}><a href={data.pricing_url} target="_blank" rel="noreferrer">{t("offers.compare")}</a></p>
        </div>
      ) : null
  return (
    <div data-billing-status={m.status}>
      {data.test_mode ? <p className="card muted" data-test-mode>{t("test_mode")}</p> : null}

      <div className="card">
        <h3 style={{ margin: "0 0 4px" }}>{t("plan.title")}</h3>
        <p style={{ fontSize: 20, margin: "4px 0" }}>
          <strong>{m.status === "free" ? t("plan.free") : data.plan.name}</strong>
        </p>
        <p className="muted">{m.status === "unknown" ? t("plan.unknown") : m.status === "paid" ? t("plan.paid.body") : t("plan.free.body")}</p>
        {m.status === "paid" ? (
          <p>
            <a href={data.manage_url} target="_blank" rel="noreferrer">{t("plan.manage")}</a> <span className="muted">· {t("plan.manage.hint")}</span>
          </p>
        ) : null}
      </div>

      {m.status !== "paid" ? offersBlock : null}

      {m.meter ? (
        <div className="card" data-usage>
          <h3 style={{ margin: "0 0 8px" }}>{t("usage.title")}</h3>
          {m.meter.unknown ? (
            <p className="muted">{t("usage.unknown")}</p>
          ) : (
            <>
              <div style={{ height: 8, borderRadius: 4, background: "var(--line)", overflow: "hidden" }}>
                <div style={{ width: `${Math.round(m.meter.fraction * 100)}%`, height: "100%", background: m.meter.over ? "var(--bad)" : "var(--accent)" }} />
              </div>
              <p style={{ margin: "6px 0 0" }}>
                {t("usage.line", { spent: usd(locale, m.meter.spentUsd), included: usd(locale, m.meter.includedUsd) })}
                {m.meter.over ? <span className="error"> · {t("usage.over", { over: usd(locale, m.meter.spentUsd - m.meter.includedUsd) })}</span> : null}
              </p>
            </>
          )}
          {data.usage ? <p className="muted" style={{ margin: "4px 0 0" }}>{t("usage.resets", { date: date(data.usage.period_end) })}</p> : null}
          {data.usage?.stopped ? <p className="error">{t("usage.stopped")}</p> : null}
        </div>
      ) : null}

      {data.credits ? (
        <div className="card" data-credits>
          <h3 style={{ margin: "0 0 4px" }}>{t("credits.title")}</h3>
          <p style={{ fontSize: 18, margin: "4px 0" }}><strong>{t("credits.balance", { amount: usd(locale, data.credits.available_usd) })}</strong></p>
          {data.credits.held_usd > 0 ? <p className="muted">{t("credits.held", { amount: usd(locale, data.credits.held_usd) })}</p> : null}
          <p className="muted">{t("credits.body")}</p>
          {m.canTopUp ? (
            <p style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
              {data.credits.topup_amounts_usd.map((a) => (
                <button key={a} onClick={() => onTopUp(a)}>{t("credits.add", { amount: usd(locale, a) })}</button>
              ))}
            </p>
          ) : null}
          {topUpError ? <p className="error">{t("error.topup", { error: topUpError })}</p> : null}
          {data.credits.entries.length === 0 ? (
            <p className="muted">{t("credits.none")}</p>
          ) : (
            <table>
              <tbody>
                {data.credits.entries.map((e, i) => (
                  <tr key={i}>
                    <td>{date(e.at)}</td>
                    <td>{KINDS.has(e.kind) ? t(`credits.kind.${e.kind}` as BillingTextKey) : e.kind}</td>
                    <td style={{ textAlign: "right" }} className="mono">{usd(locale, e.usd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      ) : null}

      {m.status === "paid" ? offersBlock : null}
    </div>
  )
}
