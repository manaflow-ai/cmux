import type { Locale } from "./approval-strings"
import type { MachineStatus, PauseReason } from "./machines"

/** Localized strings for the Machines page (English and Japanese, the languages cmux ships). */
const en = {
  "nav.machines": "Machines",
  "page.title": "Cloud machines",
  "page.intro": "Start a paused machine from here, without the Mac app. It takes about two minutes to be ready.",
  "page.signin": "Sign in to see your Cloud machines.",
  "page.loading": "Loading",
  "page.empty": "This team has no Cloud machines.",
  "page.refresh": "Refresh",
  "page.changing": "A machine is changing state. Refresh to see where it is.",
  "column.machine": "Machine",
  "column.status": "Status",
  "action.start": "Start",
  "action.starting": "Starting",
  "status.provisioning": "Creating",
  "status.starting": "Starting",
  "status.running": "Running",
  "status.pausing": "Pausing",
  "status.paused": "Paused",
  "status.deleting": "Deleting",
  "status.failed": "Failed",
  "reason.idle": "Paused after it sat idle.",
  "reason.no_report": "Paused: it stopped reporting.",
  "reason.provider_stopped": "Paused from inside the machine.",
  "reason.provider_paused": "Paused from inside the machine.",
  "started": "{name} is starting. Refresh in a minute or two to see it running."
} as const

export type MachinesTextKey = keyof typeof en

const ja: Record<MachinesTextKey, string> = {
  "nav.machines": "マシン",
  "page.title": "Cloud マシン",
  "page.intro": "一時停止中のマシンを Mac アプリなしでここから起動できます。使えるようになるまで約 2 分かかります。",
  "page.signin": "Cloud マシンを表示するにはサインインしてください。",
  "page.loading": "読み込み中",
  "page.empty": "このチームには Cloud マシンがありません。",
  "page.refresh": "更新",
  "page.changing": "状態が変わっているマシンがあります。更新すると現在の状態を確認できます。",
  "column.machine": "マシン",
  "column.status": "状態",
  "action.start": "起動",
  "action.starting": "起動中",
  "status.provisioning": "作成中",
  "status.starting": "起動中",
  "status.running": "実行中",
  "status.pausing": "一時停止中",
  "status.paused": "一時停止",
  "status.deleting": "削除中",
  "status.failed": "失敗",
  "reason.idle": "アイドル状態が続いたため一時停止しました。",
  "reason.no_report": "応答がなくなったため一時停止しました。",
  "reason.provider_stopped": "マシン内から一時停止されました。",
  "reason.provider_paused": "マシン内から一時停止されました。",
  "started": "{name} を起動しています。1〜2 分後に更新すると実行中になっています。"
}

/** A sentence per error code the list and Start answer; unknown codes get a generic one. */
const errorsEn: Record<string, string> = {
  "auth.unauthenticated": "Your session ended. Sign in again.",
  "auth.forbidden": "Your role in this team cannot start its machines.",
  "team.not_member": "You are not a member of this team.",
  "feature.disabled": "Your administrator turned off cmux Cloud.",
  "cloud.plan.required": "Your plan doesn't include Cloud machines.",
  "cloud.quota.exceeded": "You're at your plan's limit of running machines. Pause one first.",
  "cloud.quota.vm_limit": "You're at your plan's limit of running machines. Pause one first.",
  "cloud.spend_cap.reached": "Your team reached its spending cap.",
  "cloud.member_budget.reached": "You reached your monthly Cloud budget.",
  "cloud.rate_limited": "Too many changes at once. Try again in a minute.",
  "cloud.machine.not_found": "This machine no longer exists. Refresh the list.",
  "cloud.machine.not_paused": "This machine is not paused anymore. Refresh the list.",
  "cloud.machine.not_bound": "This machine never finished setting up, so it cannot start. Delete it from the Mac app or the CLI.",
  "cloud.provider.unavailable": "The Cloud service could not start the machine. Try again in a minute.",
  "mutation.indeterminate": "The Cloud service did not confirm the start. Refresh to see whether it is starting.",
  "owner.unreachable": "cmux Cloud did not answer. Try again in a minute.",
  "approval.pending": "Approve it in your Feed to finish.",
  "approval.denied": "The request was denied.",
  "approval.expired": "The approval expired. Try again.",
  "auth.sso_required": "This team requires single sign-on. Sign in with SSO first.",
  unknown: "Something went wrong. Try again."
}

const errorsJa: Record<keyof typeof errorsEn, string> = {
  "auth.unauthenticated": "セッションが終了しました。もう一度サインインしてください。",
  "auth.forbidden": "このチームでのあなたのロールではマシンを起動できません。",
  "team.not_member": "このチームのメンバーではありません。",
  "feature.disabled": "管理者が cmux Cloud をオフにしています。",
  "cloud.plan.required": "ご利用のプランには Cloud マシンが含まれていません。",
  "cloud.quota.exceeded": "プランで実行できるマシン数の上限に達しています。先にどれかを一時停止してください。",
  "cloud.quota.vm_limit": "プランで実行できるマシン数の上限に達しています。先にどれかを一時停止してください。",
  "cloud.spend_cap.reached": "チームの支出上限に達しました。",
  "cloud.member_budget.reached": "今月の Cloud 予算に達しました。",
  "cloud.rate_limited": "変更が多すぎます。1 分後にもう一度お試しください。",
  "cloud.machine.not_found": "このマシンはもう存在しません。一覧を更新してください。",
  "cloud.machine.not_paused": "このマシンはもう一時停止していません。一覧を更新してください。",
  "cloud.machine.not_bound": "このマシンはセットアップが完了していないため起動できません。Mac アプリまたは CLI から削除してください。",
  "cloud.provider.unavailable": "Cloud サービスがマシンを起動できませんでした。1 分後にもう一度お試しください。",
  "mutation.indeterminate": "Cloud サービスが起動を確認できませんでした。更新して起動中かどうかを確認してください。",
  "owner.unreachable": "cmux Cloud が応答しませんでした。1 分後にもう一度お試しください。",
  "approval.pending": "完了するにはフィードで承認してください。",
  "approval.denied": "リクエストは拒否されました。",
  "approval.expired": "承認の期限が切れました。もう一度お試しください。",
  "auth.sso_required": "このチームではシングルサインオンが必要です。先に SSO でサインインしてください。",
  unknown: "問題が発生しました。もう一度お試しください。"
}

const CATALOG: Record<Locale, Record<MachinesTextKey, string>> = { en, ja }
const ERRORS: Record<Locale, Record<string, string>> = { en: errorsEn, ja: errorsJa }

export const machinesText = (locale: Locale, key: MachinesTextKey, vars: Record<string, string> = {}): string =>
  CATALOG[locale][key].replace(/\{(\w+)\}/g, (m, name: string) => vars[name] ?? m)

export const machinesErrorText = (locale: Locale, code: string): string => ERRORS[locale][code] ?? ERRORS[locale].unknown!

export const statusText = (locale: Locale, status: MachineStatus): string => machinesText(locale, `status.${status}`)

export const pauseReasonText = (locale: Locale, reason: PauseReason): string => machinesText(locale, `reason.${reason}`)
