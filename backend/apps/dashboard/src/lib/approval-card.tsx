import type { CSSProperties } from "react"
import { absoluteTime, approvalText, relativeTime, type ApprovalTextKey, type Locale } from "./approval-strings"
import { approvalStatus, canApprove, canDeny, canonicalJson, type ApprovalStatus, type ApprovalView, type DigestCheck, type ParsedApproval } from "./approvals"

export interface ApprovalCardProps {
  readonly approval: ParsedApproval
  /** integration.approval.get for this session; null when it cannot read it. */
  readonly view: ApprovalView | null
  readonly digest: DigestCheck
  readonly now: number
  readonly locale: Locale
  readonly open: boolean
  readonly busy: boolean
  readonly onToggle: () => void
  readonly onApprove: () => void
  readonly onDeny: () => void
}

const pill = (color: string): CSSProperties => ({ display: "inline-block", padding: "0 8px", borderRadius: 999, border: `1px solid ${color}`, color, fontSize: 12, lineHeight: "20px", whiteSpace: "nowrap" })

const STATUS_COLOR: Record<ApprovalStatus, string> = {
  pending: "var(--accent)",
  running: "var(--accent)",
  approved: "var(--fg)",
  denied: "var(--bad)",
  expired: "var(--muted)",
  stale: "var(--bad)",
  withdrawn: "var(--muted)"
}

const RISKS = new Set(["send-external", "money", "destructive"])

/** The pretty canonical JSON of the parameters: the exact object whose digest the request names. */
const pretty = (params: unknown) => JSON.stringify(JSON.parse(canonicalJson(params)), null, 2)

/** One integration approval request: who asks (an integration), what, until when, and Approve or Deny. */
export function ApprovalCard({ approval: a, view, digest, now, locale, open, busy, onToggle, onApprove, onDeny }: ApprovalCardProps) {
  const t = (key: ApprovalTextKey, vars?: Record<string, string>) => approvalText(locale, key, vars)
  const status = approvalStatus(a, view, digest, now)
  const expiresAt = view?.expires_at ?? a.expiresAt
  const live = status === "pending" || status === "stale" || status === "running"
  const target = view?.target || a.target
  const summary = view?.summary || a.summary
  return (
    <div className="card" data-poster="integration" data-status={status} style={{ borderLeft: "3px solid var(--accent)" }}>
      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <span style={pill("var(--accent)")}>{t("poster.integration")}</span>
        <code>{a.op}</code>
        <span style={pill(STATUS_COLOR[status])}>{t(`status.${status}`)}</span>
        <span style={{ flex: 1 }} />
        <button onClick={onToggle} aria-expanded={open}>
          {open ? t("action.hide") : t("action.review")}
        </button>
      </div>
      <div style={{ marginTop: 6 }}>
        {target ? (
          <span>
            <span className="muted">{t("field.target")}: </span>
            {target}
          </span>
        ) : null}
        {summary ? (
          <span>
            {target ? " · " : null}
            <span className="muted">{t("field.summary")}: </span>
            {summary}
          </span>
        ) : null}
      </div>
      <div className="muted">
        {RISKS.has(a.risk) ? t(`risk.${a.risk}` as ApprovalTextKey) : null}
        {RISKS.has(a.risk) && (live || status === "expired") ? " · " : null}
        {live ? t("time.expires", { when: relativeTime(locale, expiresAt, now) }) : status === "expired" ? t("time.expired", { when: relativeTime(locale, expiresAt, now) }) : null}
      </div>
      <p className={status === "stale" || status === "denied" ? "error" : undefined} style={{ margin: "6px 0" }}>
        {t(`detail.${status}`)}
      </p>
      {canApprove(status, digest) || canDeny(a, status) ? (
        <div style={{ display: "flex", gap: 8 }}>
          {canApprove(status, digest) ? (
            <button disabled={busy} onClick={onApprove} style={{ borderColor: "var(--accent)", color: "var(--accent)" }}>
              {t("action.approve")}
            </button>
          ) : null}
          {canDeny(a, status) ? (
            <button className="danger" disabled={busy} onClick={onDeny}>
              {t("action.deny")}
            </button>
          ) : null}
        </div>
      ) : null}
      {open ? <ApprovalDetail approval={a} view={view} digest={digest} locale={locale} /> : null}
    </div>
  )
}

function ApprovalDetail({ approval: a, view, digest, locale }: Pick<ApprovalCardProps, "approval" | "view" | "digest" | "locale">) {
  const t = (key: ApprovalTextKey) => approvalText(locale, key)
  if (!view) return <p className="muted">{t("view.unavailable")}</p>
  const final = view.state !== "pending"
  return (
    <div style={{ marginTop: 10 }}>
      <table>
        <tbody>
          <tr>
            <th>{t("field.action")}</th>
            <td className="mono">{view.op}</td>
          </tr>
          <tr>
            <th>{t("field.connection")}</th>
            <td className="mono">{view.connection}</td>
          </tr>
          <tr>
            <th>{t("field.requested")}</th>
            <td>{absoluteTime(locale, view.created_at)}</td>
          </tr>
          <tr>
            <th>{t("field.digest")}</th>
            <td className="mono" style={{ wordBreak: "break-all" }}>
              {a.digest}
            </td>
          </tr>
        </tbody>
      </table>
      <p className={digest === "mismatch" ? "error" : "muted"}>{final ? t("digest.final") : digest === "match" ? t("digest.match") : digest === "mismatch" ? t("detail.stale") : t("digest.checking")}</p>
      {final ? null : (
        <>
          <strong>{t("field.params")}</strong>
          <pre className="mono" style={{ whiteSpace: "pre-wrap", wordBreak: "break-word", maxHeight: 360, overflow: "auto", margin: "6px 0 0" }}>
            {pretty(view.params)}
          </pre>
        </>
      )}
    </div>
  )
}
