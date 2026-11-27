import { useSyncExternalStore } from "react"

/**
 * Localized strings for the integration approvals view (English and Japanese, the languages cmux
 * ships). The server render uses English; the browser switches to the person's language after
 * hydration through useSyncExternalStore (no effect).
 */
export type Locale = "en" | "ja"

const en = {
  "section.title": "Waiting for your approval",
  "section.intro": "Agents, automations and apps asked to send, spend or delete through your integrations. Nothing runs until you approve it here. A request expires after 24 hours.",
  "section.empty": "No approval requests.",
  "section.loading": "Loading",
  "section.refresh": "Refresh",
  "poster.integration": "Integration",
  "status.pending": "Waiting",
  "status.running": "Approved, running",
  "status.answered": "Approved",
  "status.approved": "Approved",
  "status.revoked": "Not run",
  "status.denied": "Denied",
  "status.expired": "Expired",
  "status.stale": "Digest mismatch",
  "status.withdrawn": "Withdrawn",
  "detail.pending": "Nothing runs until you decide.",
  "detail.running": "You approved it. It runs once.",
  "detail.answered": "You approved it. Its outcome is not available in this session.",
  "detail.approved": "You approved it. It was sent to the provider once.",
  "detail.revoked": "You approved it, but the requester is no longer allowed to run it. Nothing ran.",
  "detail.denied": "Denied. Nothing ran.",
  "detail.expired": "No answer within 24 hours. Nothing ran.",
  "detail.stale": "The request changed after it was posted (stale digest), so it cannot be approved. Nothing ran. Deny it, or let it expire.",
  "detail.stale_closed": "The request changed after it was posted (stale digest), so your approval was refused. Nothing ran. It ends when it expires.",
  "detail.withdrawn": "The requester withdrew it. Nothing ran.",
  "field.action": "Action",
  "field.target": "Target",
  "field.summary": "Summary",
  "field.connection": "Connection",
  "field.params": "Full request",
  "field.digest": "Digest",
  "field.requested": "Requested",
  "time.expires": "Expires {when}",
  "time.expired": "Expired {when}",
  "risk.send-external": "Sends outside cmux",
  "risk.money": "Spends money",
  "risk.destructive": "Deletes or overwrites data",
  "action.approve": "Approve",
  "action.deny": "Deny",
  "action.review": "Review",
  "action.hide": "Hide",
  "digest.checking": "Checking the request digest.",
  "digest.match": "The parameters below match the digest of the request.",
  "digest.final": "The parameters were deleted when the request ended.",
  "digest.error": "This browser could not check the request digest, so it cannot approve. Use a secure (https) page.",
  "view.unavailable": "This session cannot read the full request. It may belong to another team, or it was removed.",
  "error.answer": "Your answer was not sent: {error}",
  "error.load": "Approval requests did not load: {error}"
} as const

export type ApprovalTextKey = keyof typeof en

const ja: Record<ApprovalTextKey, string> = {
  "section.title": "承認待ち",
  "section.intro": "エージェント、オートメーション、アプリが連携サービスを通じた送信、支払い、削除を求めています。ここで承認するまで何も実行されません。リクエストは 24 時間で期限切れになります。",
  "section.empty": "承認リクエストはありません。",
  "section.loading": "読み込み中",
  "section.refresh": "更新",
  "poster.integration": "連携",
  "status.pending": "待機中",
  "status.running": "承認済み、実行中",
  "status.answered": "承認済み",
  "status.approved": "承認済み",
  "status.revoked": "未実行",
  "status.denied": "拒否済み",
  "status.expired": "期限切れ",
  "status.stale": "ダイジェスト不一致",
  "status.withdrawn": "取り下げ",
  "detail.pending": "決定するまで何も実行されません。",
  "detail.running": "承認しました。1 回だけ実行されます。",
  "detail.answered": "承認しました。このセッションでは結果を確認できません。",
  "detail.approved": "承認しました。プロバイダーに 1 回だけ送信されました。",
  "detail.revoked": "承認しましたが、リクエスト元に実行権限がなくなりました。何も実行されていません。",
  "detail.denied": "拒否しました。何も実行されていません。",
  "detail.expired": "24 時間以内に回答がありませんでした。何も実行されていません。",
  "detail.stale": "投稿後にリクエストが変更されたため (ダイジェスト不一致)、承認できません。何も実行されていません。拒否するか、期限切れになるまで待ってください。",
  "detail.stale_closed": "投稿後にリクエストが変更されたため (ダイジェスト不一致)、承認は拒否されました。何も実行されていません。期限切れで終了します。",
  "detail.withdrawn": "リクエスト元が取り下げました。何も実行されていません。",
  "field.action": "操作",
  "field.target": "対象",
  "field.summary": "概要",
  "field.connection": "接続",
  "field.params": "リクエスト全体",
  "field.digest": "ダイジェスト",
  "field.requested": "リクエスト日時",
  "time.expires": "期限: {when}",
  "time.expired": "期限切れ: {when}",
  "risk.send-external": "cmux の外部に送信",
  "risk.money": "支払いが発生",
  "risk.destructive": "データを削除または上書き",
  "action.approve": "承認",
  "action.deny": "拒否",
  "action.review": "確認",
  "action.hide": "閉じる",
  "digest.checking": "リクエストのダイジェストを確認しています。",
  "digest.match": "以下のパラメーターはリクエストのダイジェストと一致しています。",
  "digest.final": "リクエストの終了時にパラメーターは削除されました。",
  "digest.error": "このブラウザーではリクエストのダイジェストを確認できないため、承認できません。安全な (https) ページを使用してください。",
  "view.unavailable": "このセッションではリクエスト全体を読み取れません。別のチームのリクエストか、削除された可能性があります。",
  "error.answer": "回答を送信できませんでした: {error}",
  "error.load": "承認リクエストを読み込めませんでした: {error}"
}

const CATALOG: Record<Locale, Record<ApprovalTextKey, string>> = { en, ja }

/** The first supported language in the browser's preference list; English otherwise. */
export const pickLocale = (languages: ReadonlyArray<string>): Locale => {
  for (const l of languages) {
    const base = l.toLowerCase().split("-")[0]
    if (base === "ja" || base === "en") return base
  }
  return "en"
}

export const approvalText = (locale: Locale, key: ApprovalTextKey, vars: Record<string, string> = {}): string =>
  CATALOG[locale][key].replace(/\{(\w+)\}/g, (m, name: string) => vars[name] ?? m)

/** "in 23 hours" / "23 時間後": hours from one hour on, minutes below. */
export const relativeTime = (locale: Locale, at: number, now: number): string => {
  const diff = at - now
  const fmt = new Intl.RelativeTimeFormat(locale, { numeric: "always" })
  return Math.abs(diff) >= 3_600_000 ? fmt.format(Math.round(diff / 3_600_000), "hour") : fmt.format(Math.round(diff / 60_000), "minute")
}

export const absoluteTime = (locale: Locale, at: number): string => new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(at)

const subscribe = (onChange: () => void) => {
  window.addEventListener("languagechange", onChange)
  return () => window.removeEventListener("languagechange", onChange)
}

/** The person's language in the browser; English during the server render. */
export const useLocale = (): Locale =>
  useSyncExternalStore(
    subscribe,
    () => pickLocale(navigator.languages ?? [navigator.language]),
    () => "en"
  )
