import type { Locale } from "./approval-strings"

/** Localized strings for the AI spending section of the Team page (cx-ds09i; English and Japanese, the languages cmux ships). */
const en = {
  "section.title": "AI spending",
  "section.intro": "Each member has a monthly limit on AI model use. A personal limit wins over the team default. Limits reset on {date}.",
  "default.label": "Monthly AI limit per member",
  "default.uses_cmux": "Uses the cmux default ({amount})",
  "default.save": "Save",
  "default.reset": "Use the cmux default",
  "default.invalid": "Enter an amount of 0 or more. 0 turns AI off for members.",
  "col.spend": "AI spend this month",
  "col.limit": "Monthly AI limit",
  "limit.team": "{amount} (team default)",
  "limit.default": "{amount} (cmux default)",
  "limit.personal": "{amount} (personal limit)",
  "limit.edit": "Edit",
  "limit.clear": "Use team default",
  "limit.save": "Save",
  "limit.cancel": "Cancel",
  "spend.unknown": "Not available",
  "me.line": "Your AI spend this month: {spent} of {limit}. Resets on {date}.",
  "changes.title": "Recent limit changes",
  "changes.empty": "No limit changes yet.",
  "changes.row": "{when}: {who} changed {what} from {before} to {after}",
  "changes.team": "the team default",
  "changes.member": "the limit of {member}",
  "changes.removed": "{member} left the team; their personal limit ({amount}) was removed",
  "value.default": "the default",
  "error.load": "AI limits did not load: {error}",
  "error.save": "The limit was not saved: {error}"
} as const

export type AiLimitTextKey = keyof typeof en

const ja: Record<AiLimitTextKey, string> = {
  "section.title": "AI の利用額",
  "section.intro": "メンバーごとに AI モデル利用の月間上限があります。個人の上限はチームの既定値より優先されます。上限は {date} にリセットされます。",
  "default.label": "メンバーあたりの月間 AI 上限",
  "default.uses_cmux": "cmux の既定値 ({amount}) を使用中",
  "default.save": "保存",
  "default.reset": "cmux の既定値を使う",
  "default.invalid": "0 以上の金額を入力してください。0 にするとメンバーは AI を使えません。",
  "col.spend": "今月の AI 利用額",
  "col.limit": "月間 AI 上限",
  "limit.team": "{amount} (チームの既定値)",
  "limit.default": "{amount} (cmux の既定値)",
  "limit.personal": "{amount} (個人の上限)",
  "limit.edit": "編集",
  "limit.clear": "チームの既定値を使う",
  "limit.save": "保存",
  "limit.cancel": "キャンセル",
  "spend.unknown": "取得できません",
  "me.line": "今月のあなたの AI 利用額: {spent} / {limit}。{date} にリセットされます。",
  "changes.title": "最近の上限の変更",
  "changes.empty": "上限の変更はまだありません。",
  "changes.row": "{when}: {who} が {what} を {before} から {after} に変更",
  "changes.team": "チームの既定値",
  "changes.member": "{member} の上限",
  "changes.removed": "{member} がチームを離れたため、個人の上限 ({amount}) を削除しました",
  "value.default": "既定値",
  "error.load": "AI の上限を読み込めませんでした: {error}",
  "error.save": "上限を保存できませんでした: {error}"
}

const CATALOG: Record<Locale, Record<AiLimitTextKey, string>> = { en, ja }

export const aiLimitText = (locale: Locale, key: AiLimitTextKey, vars: Record<string, string> = {}): string =>
  CATALOG[locale][key].replace(/\{(\w+)\}/g, (m, name: string) => vars[name] ?? m)

/** USD with two decimals at most (spend can be fractions of a cent: shown as "<$0.01"). */
export const usd = (locale: Locale, v: number) =>
  v > 0 && v < 0.01 ? "<$0.01" : new Intl.NumberFormat(locale === "ja" ? "ja-JP" : "en-US", { style: "currency", currency: "USD", maximumFractionDigits: 2 }).format(v)
