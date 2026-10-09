import type { Locale } from "./approval-strings"

/** Localized strings for the team picker and the team scope states (English and Japanese, the languages cmux ships). */
const en = {
  "picker.label": "Team",
  "picker.personal": "Personal",
  "picker.option": "{name} ({role})",
  "picker.unknown": "Team {id}",
  "picker.loading": "Loading teams",
  "picker.error": "The team list did not load: {error}",
  "picker.incomplete": "cmux could not check some teams now. Reload to try again.",
  "role.owner": "owner",
  "role.admin": "admin",
  "role.member": "member",
  "forbidden.title": "You are not a member of this team",
  "forbidden.body": "cmux refused team {id}. You were removed from this team, or the link names a team that you are not in.",
  "forbidden.personal": "Open my personal team"
} as const

export type TeamTextKey = keyof typeof en

const ja: Record<TeamTextKey, string> = {
  "picker.label": "チーム",
  "picker.personal": "個人",
  "picker.option": "{name} ({role})",
  "picker.unknown": "チーム {id}",
  "picker.loading": "チームを読み込み中",
  "picker.error": "チームの一覧を読み込めませんでした: {error}",
  "picker.incomplete": "一部のチームを今は確認できませんでした。再読み込みしてください。",
  "role.owner": "オーナー",
  "role.admin": "管理者",
  "role.member": "メンバー",
  "forbidden.title": "このチームのメンバーではありません",
  "forbidden.body": "cmux はチーム {id} へのアクセスを拒否しました。このチームから削除されたか、リンクが参加していないチームを指しています。",
  "forbidden.personal": "個人チームを開く"
}

const CATALOG: Record<Locale, Record<TeamTextKey, string>> = { en, ja }

export const teamText = (locale: Locale, key: TeamTextKey, vars: Record<string, string> = {}): string =>
  CATALOG[locale][key].replace(/\{(\w+)\}/g, (m, name: string) => vars[name] ?? m)
