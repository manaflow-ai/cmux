import { useState } from "react"
import { ApprovalCard } from "../../lib/approval-card"
import { approvalText, useLocale } from "../../lib/approval-strings"
import { checkDigest, parseApproval, type ApprovalView, type DigestCheck, type ParsedApproval } from "../../lib/approvals"
import { useLoad } from "../../lib/hooks"
import { mutate, read } from "../../lib/server"
import { newKey, setSignedIn } from "../../lib/session"

interface Row {
  readonly approval: ParsedApproval
  readonly view: ApprovalView | null
  readonly digest: DigestCheck
}

/** Newest first; older ones stay in the feed. */
const LIMIT = 20

const loadRows = async (): Promise<Array<Row>> => {
  const r = await read({ data: { op: "feed.list", params: { poster_kind: "integration", kind: "approve", state: "all", order: "recent", limit: LIMIT } } })
  if (r.status === 401) setSignedIn(false)
  if (r.status !== 200) throw new Error(`feed.list ${r.status}`)
  const items = ((r.body.value as { items?: Array<unknown> } | null)?.items ?? []).map(parseApproval).filter((a): a is ParsedApproval => a !== null)
  return Promise.all(
    items.map(async (approval) => {
      // Only this session reads the full request (G8); a request of another team or a pruned one reads as not found.
      const v = await read({ data: { op: "integration.approval.get", params: { request: approval.request } } })
      const view = v.status === 200 ? (v.body.value as unknown as ApprovalView) : null
      return { approval, view, digest: view ? await checkDigest(approval, view) : null }
    })
  )
}

/**
 * G8 approval requests on the Integrations page: risky provider ops that agents, automations and
 * apps asked to run. Only the person's own session answers them, here.
 */
export function IntegrationApprovals() {
  const locale = useLocale()
  const t = (key: Parameters<typeof approvalText>[1], vars?: Record<string, string>) => approvalText(locale, key, vars)
  const rows = useLoad<Array<Row>>("integration-approvals", loadRows)
  const [open, setOpen] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const answer = async (a: ParsedApproval, decision: "allow" | "deny") => {
    setBusy(a.item)
    setError(null)
    const value = decision === "allow" ? { decision: "allow", scope: "once" } : { decision: "deny" }
    const r = await mutate({ data: { op: "feed.answer", params: { item: a.item, answer: value }, idempotency_key: newKey() } })
    if (r.status === 401) setSignedIn(false)
    else if (!r.body.ok) setError(t("error.answer", { error: `${r.body.error?.code ?? r.status}: ${r.body.error?.message ?? ""}` }))
    setBusy(null)
    rows.reload()
  }

  const now = Date.now()
  return (
    <section>
      <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
        <h3 style={{ margin: "16px 0 4px" }}>{t("section.title")}</h3>
        <span style={{ flex: 1 }} />
        <button disabled={rows.loading} onClick={rows.reload}>
          {t("section.refresh")}
        </button>
      </div>
      <p className="muted" style={{ marginTop: 0 }}>
        {t("section.intro")}
      </p>
      {rows.error ? <p className="error">{t("error.load", { error: rows.error })}</p> : null}
      {error ? <p className="error">{error}</p> : null}
      {(rows.data ?? []).map((row) => (
        <ApprovalCard
          key={row.approval.item}
          approval={row.approval}
          view={row.view}
          digest={row.digest}
          now={now}
          locale={locale}
          open={open === row.approval.item}
          busy={busy === row.approval.item}
          onToggle={() => setOpen((o) => (o === row.approval.item ? null : row.approval.item))}
          onApprove={() => void answer(row.approval, "allow")}
          onDeny={() => void answer(row.approval, "deny")}
        />
      ))}
      {rows.data && rows.data.length === 0 ? <p className="muted">{t("section.empty")}</p> : null}
      {rows.loading && !rows.data ? <p className="muted">{t("section.loading")}</p> : null}
    </section>
  )
}
