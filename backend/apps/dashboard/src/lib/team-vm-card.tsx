import type { CSSProperties } from "react"
import { absoluteTime, type Locale } from "./approval-strings"
import { teamVmErrorText, teamVmText, type TeamVmTextKey } from "./team-vm-strings"
import { canManageTeamVm, MAX_RETIRED, taintBadge, teamVmRequest, type CardState, type Dialog, type TaintBadge, type TeamRole, type TeamVmRetired, type TeamVmView } from "./team-vm"

export interface TeamVmCardProps {
  readonly view: TeamVmView
  /** The person's role in the team; null while unknown (no actions). */
  readonly role: TeamRole | null
  readonly locale: Locale
  readonly state: CardState
  readonly onOpen: (kind: Dialog["kind"], vm?: string) => void
  readonly onCancel: () => void
  readonly onFilesCopied: (value: boolean) => void
  readonly onConfirm: () => void
}

const pill = (color: string): CSSProperties => ({ display: "inline-block", padding: "0 8px", borderRadius: 999, border: `1px solid ${color}`, color, fontSize: 12, lineHeight: "20px", whiteSpace: "nowrap" })

const BADGE_COLOR: Record<TaintBadge, string> = { clean: "var(--muted)", tainted: "var(--bad)", accepted: "var(--accent)" }

const accentButton: CSSProperties = { borderColor: "var(--accent)", color: "var(--accent)" }

/** The shared button CSS has no disabled look; a disabled action reads as off. */
const dim = (disabled: boolean, style?: CSSProperties): CSSProperties | undefined => (disabled ? { ...style, opacity: 0.45, cursor: "not-allowed" } : style)

/** The team VM: state, taint badge (every member), owner/admin actions and the retired VMs. */
export function TeamVmCard({ view, role, locale, state, onOpen, onCancel, onFilesCopied, onConfirm }: TeamVmCardProps) {
  const t = (key: TeamVmTextKey, vars?: Record<string, string>) => teamVmText(locale, key, vars)
  const badge = taintBadge(view)
  const manage = canManageTeamVm(role)
  const full = view.retired.length >= MAX_RETIRED
  const taint = view.taint
  return (
    <div className="card" data-taint={badge} style={badge === "tainted" ? { borderLeft: "3px solid var(--bad)" } : undefined}>
      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <strong>{t("card.title")}</strong>
        <span style={pill("var(--fg)")}>{t(`status.${view.status}`)}</span>
        <span style={pill(BADGE_COLOR[badge])}>{t(`badge.${badge}`)}</span>
        <span style={{ flex: 1 }} />
        {view.vm ? (
          <span className="muted">
            {t("field.vm")} <code>{view.vm}</code> · {t("field.epoch")} {view.epoch}
          </span>
        ) : null}
      </div>
      {taint ? (
        <div style={{ marginTop: 8 }}>
          <p style={{ margin: "4px 0" }} className={badge === "tainted" ? "error" : undefined}>
            {t("taint.detail")}
          </p>
          {badge === "tainted" ? <p style={{ margin: "4px 0" }}>{t("taint.blocked")}</p> : null}
          <p className="muted" style={{ margin: "4px 0" }}>
            {t("taint.users")}:{" "}
            {taint.users.map((u, i) => (
              <span key={u}>
                {i > 0 ? ", " : null}
                <code>{u}</code>
              </span>
            ))}{" "}
            · {t("taint.since", { when: absoluteTime(locale, taint.at) })}
          </p>
          {taint.accepted_by ? <p style={{ margin: "4px 0" }}>{t("taint.accepted", { who: taint.accepted_by, when: absoluteTime(locale, taint.accepted_at ?? taint.at) })}</p> : null}
          {badge === "tainted" && !manage ? <p className="muted" style={{ margin: "4px 0" }}>{t("taint.member_hint")}</p> : null}
        </div>
      ) : null}
      {manage && view.vm ? (
        <div style={{ display: "flex", gap: 8, marginTop: 8, alignItems: "center", flexWrap: "wrap" }}>
          {badge === "tainted" ? (
            <button disabled={state.busy} onClick={() => onOpen("accept")} style={dim(state.busy)}>
              {t("action.accept")}
            </button>
          ) : null}
          <button disabled={state.busy || full} onClick={() => onOpen("rebuild")} style={dim(state.busy || full, full ? undefined : accentButton)}>
            {t("action.rebuild")}
          </button>
          {full ? <span className="muted">{t("rebuild.full")}</span> : null}
        </div>
      ) : null}
      {state.dialog && state.dialog.kind !== "delete" ? <Confirm view={view} locale={locale} state={state} onCancel={onCancel} onFilesCopied={onFilesCopied} onConfirm={onConfirm} /> : null}
      {view.retired.length > 0 ? <Retired view={view} manage={manage} locale={locale} state={state} onOpen={onOpen} onCancel={onCancel} onFilesCopied={onFilesCopied} onConfirm={onConfirm} /> : null}
    </div>
  )
}

type ConfirmProps = Pick<TeamVmCardProps, "view" | "locale" | "state" | "onCancel" | "onFilesCopied" | "onConfirm">

function Retired({ view, manage, locale, state, onOpen, ...confirm }: ConfirmProps & Pick<TeamVmCardProps, "onOpen"> & { readonly manage: boolean }) {
  const t = (key: TeamVmTextKey, vars?: Record<string, string>) => teamVmText(locale, key, vars)
  const deleting = state.dialog?.kind === "delete" ? state.dialog.vm : null
  return (
    <div style={{ marginTop: 12 }}>
      <strong>{t("retired.title")}</strong>
      <p className="muted" style={{ margin: "2px 0 6px" }}>
        {t("retired.intro")}
      </p>
      <table>
        <tbody>
          {view.retired.map((r: TeamVmRetired) => (
            <tr key={r.vm} data-retired={r.vm}>
              <td>
                <code>{r.vm}</code>
                <br />
                <span className="muted">
                  {t("field.epoch")} {r.epoch}
                </span>
                {r.tainted_by.length > 0 ? (
                  <>
                    <br />
                    <span className="muted">
                      {t("taint.users")}: {r.tainted_by.join(", ")}
                    </span>
                  </>
                ) : null}
              </td>
              <td>{t(`retired.${r.state}`)}</td>
              <td className="muted">{t("retired.by", { who: r.by, when: absoluteTime(locale, r.at) })}</td>
              <td style={{ textAlign: "right" }}>
                {manage && r.state === "paused" ? (
                  <button className="danger" data-delete={r.vm} disabled={state.busy || deleting === r.vm} onClick={() => onOpen("delete", r.vm)} style={dim(state.busy || deleting === r.vm)}>
                    {t("action.delete")}
                  </button>
                ) : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {deleting ? <Confirm view={view} locale={locale} state={state} {...confirm} /> : null}
    </div>
  )
}

/** The confirm panel of the open dialog: what the op does, and for Delete the required files-copied checkbox. */
function Confirm({ view, locale, state, onCancel, onFilesCopied, onConfirm }: ConfirmProps) {
  const t = (key: TeamVmTextKey, vars?: Record<string, string>) => teamVmText(locale, key, vars)
  const dialog = state.dialog
  if (!dialog) return null
  const ready = teamVmRequest(view, dialog) !== null && !state.busy
  const danger = dialog.kind !== "accept"
  return (
    <div role="alertdialog" aria-labelledby="team-vm-confirm-title" data-dialog={dialog.kind} style={{ marginTop: 10, padding: 12, border: `1px solid ${danger ? "var(--bad)" : "var(--line)"}`, borderRadius: 8 }}>
      <strong id="team-vm-confirm-title">{dialog.kind === "delete" ? t("confirm.delete.title", { vm: dialog.vm }) : t(`confirm.${dialog.kind}.title`)}</strong>
      {dialog.kind === "rebuild" ? (
        <>
          <p style={{ margin: "6px 0" }}>{t("confirm.rebuild.body", { epoch: String(view.epoch + 1) })}</p>
          <p className="error" style={{ margin: "6px 0", fontWeight: 600 }}>
            {t("confirm.rebuild.files")}
          </p>
        </>
      ) : (
        <p style={{ margin: "6px 0" }}>{t(`confirm.${dialog.kind}.body`)}</p>
      )}
      {dialog.kind === "delete" ? (
        <label style={{ display: "flex", gap: 6, alignItems: "center", margin: "6px 0" }}>
          <input type="checkbox" checked={dialog.filesCopied} disabled={state.busy} onChange={(e) => onFilesCopied(e.currentTarget.checked)} />
          {t("confirm.delete.check")}
        </label>
      ) : null}
      {state.error ? (
        <p className="error" data-error={state.error.code} style={{ margin: "6px 0" }}>
          {t("error.prefix", { code: state.error.code, text: teamVmErrorText(locale, state.error.code) })}
        </p>
      ) : null}
      <div style={{ display: "flex", gap: 8, marginTop: 6 }}>
        <button className={danger ? "danger" : undefined} data-confirm={dialog.kind} disabled={!ready} onClick={onConfirm} style={dim(!ready, danger ? { borderColor: "var(--bad)" } : accentButton)}>
          {t(`confirm.${dialog.kind}.button`)}
        </button>
        <button disabled={state.busy} onClick={onCancel} style={dim(state.busy)}>
          {t("action.cancel")}
        </button>
      </div>
    </div>
  )
}
