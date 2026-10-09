import type { Locale } from "./approval-strings"
import type { UserTeam } from "./team-scope"
import { teamText } from "./team-strings"

/** A team's label: the personal team by its localized name, a shared team by its name, each with the caller's role. */
export const teamLabel = (locale: Locale, t: UserTeam): string =>
  teamText(locale, "picker.option", {
    name: t.kind === "personal" ? teamText(locale, "picker.personal") : t.display_name || t.id,
    role: roleText(locale, t.role)
  })

/** A role this build has no string for (a newer server role) shows as the server named it. */
const roleText = (locale: Locale, role: string): string => {
  const key = `role.${role}`
  return key === "role.owner" || key === "role.admin" || key === "role.member" ? teamText(locale, key) : role
}

export interface TeamPickerProps {
  readonly teams: ReadonlyArray<UserTeam>
  /** The URL's team; undefined = the personal team. */
  readonly selected: string | undefined
  readonly locale: Locale
  readonly onSelect: (team: string) => void
}

/** The header team picker (cx-5xew): the teams user.teams.list confirmed, plus the URL's team when the list does not have it. */
export function TeamPicker({ teams, selected, locale, onSelect }: TeamPickerProps) {
  const current = selected ?? teams.find((t) => t.kind === "personal")?.id ?? ""
  const unknown = current !== "" && !teams.some((t) => t.id === current)
  return (
    <label data-team-picker="" style={{ display: "flex", gap: 6, alignItems: "center" }}>
      <span className="muted">{teamText(locale, "picker.label")}</span>
      <select value={current} onChange={(e) => onSelect(e.currentTarget.value)}>
        {teams.map((t) => (
          <option key={t.id} value={t.id}>
            {teamLabel(locale, t)}
          </option>
        ))}
        {unknown ? <option value={current}>{teamText(locale, "picker.unknown", { id: current })}</option> : null}
      </select>
    </label>
  )
}

/** The state for a team the API refused (auth.forbidden): not a member now, for example after a removal. */
export function TeamForbidden({ team, locale, onPersonal }: { readonly team: string; readonly locale: Locale; readonly onPersonal: () => void }) {
  return (
    <div className="card" data-team-forbidden="" role="alert">
      <h3 className="error">{teamText(locale, "forbidden.title")}</h3>
      <p>{teamText(locale, "forbidden.body", { id: team })}</p>
      <button onClick={onPersonal}>{teamText(locale, "forbidden.personal")}</button>
    </div>
  )
}
