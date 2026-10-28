import type { Locale } from "./approval-strings"

/** Localized strings for the Billing page (paid-plans-DESIGN.md; English and Japanese, the languages cmux ships). */
const en = {
  "nav.billing": "Billing",
  "title": "Billing",
  "test_mode": "Test mode: payments use Stripe test cards. Nothing is charged.",
  "plan.title": "Your plan",
  "plan.free": "Free",
  "plan.free.body": "Upgrade for Cloud machines and included AI usage every month.",
  "plan.paid.body": "Thank you for supporting cmux.",
  "plan.unknown": "Your plan could not be read now. Try again in a minute.",
  "plan.manage": "Manage subscription",
  "plan.manage.hint": "Change plan, payment method, invoices, or cancel.",
  "usage.title": "AI usage this period",
  "usage.line": "{spent} of {included} included",
  "usage.over": "{over} above the included amount",
  "usage.unknown": "Usage is not available now.",
  "usage.resets": "Resets on {date}.",
  "usage.stopped": "The included amount is used up. AI pauses until the reset or a top-up.",
  "credits.title": "cmux credits",
  "credits.balance": "Available: {amount}",
  "credits.held": "{amount} held for running calls",
  "credits.body": "Credits pay for AI and Cloud usage above your plan.",
  "credits.add": "Add {amount}",
  "credits.none": "No credit activity yet.",
  "credits.kind.topup": "Top-up",
  "credits.kind.grant": "Grant",
  "credits.kind.charge": "Usage",
  "credits.kind.expired": "Expired hold",
  "credits.kind.correction": "Correction",
  "credits.kind.opening": "Opening balance",
  "offers.title": "Upgrade",
  "offers.recommended": "Recommended",
  "offers.month": "{price}/month",
  "offers.choose": "Choose {plan}",
  "offers.compare": "Compare plans",
  "error.load": "Billing did not load: {error}",
  "error.topup": "The payment page did not open: {error}",
  "signin": "Sign in to see your billing."
} as const

export type BillingTextKey = keyof typeof en

const ja: Record<BillingTextKey, string> = {
  "nav.billing": "請求",
  "title": "請求",
  "test_mode": "テストモード: 支払いには Stripe のテストカードを使います。請求は発生しません。",
  "plan.title": "現在のプラン",
  "plan.free": "無料",
  "plan.free.body": "アップグレードすると、Cloud マシンと毎月の AI 利用枠が使えます。",
  "plan.paid.body": "cmux を支えていただきありがとうございます。",
  "plan.unknown": "現在プランを読み込めません。1 分ほどしてからもう一度お試しください。",
  "plan.manage": "サブスクリプションを管理",
  "plan.manage.hint": "プランの変更、支払い方法、請求書、解約。",
  "usage.title": "今期の AI 利用",
  "usage.line": "含まれる {included} のうち {spent}",
  "usage.over": "含まれる額を {over} 超過",
  "usage.unknown": "現在利用状況を表示できません。",
  "usage.resets": "{date} にリセットされます。",
  "usage.stopped": "含まれる額を使い切りました。リセットかチャージまで AI は停止します。",
  "credits.title": "cmux クレジット",
  "credits.balance": "利用可能: {amount}",
  "credits.held": "実行中の呼び出しのため {amount} を確保中",
  "credits.body": "クレジットはプランを超えた AI と Cloud の利用に使われます。",
  "credits.add": "{amount} を追加",
  "credits.none": "クレジットの履歴はまだありません。",
  "credits.kind.topup": "チャージ",
  "credits.kind.grant": "付与",
  "credits.kind.charge": "利用",
  "credits.kind.expired": "期限切れの確保",
  "credits.kind.correction": "修正",
  "credits.kind.opening": "初期残高",
  "offers.title": "アップグレード",
  "offers.recommended": "おすすめ",
  "offers.month": "{price}/月",
  "offers.choose": "{plan} を選ぶ",
  "offers.compare": "プランを比較",
  "error.load": "請求情報を読み込めませんでした: {error}",
  "error.topup": "支払いページを開けませんでした: {error}",
  "signin": "請求情報を見るにはサインインしてください。"
}

const CATALOG: Record<Locale, Record<BillingTextKey, string>> = { en, ja }

export const billingText = (locale: Locale, key: BillingTextKey, vars: Record<string, string> = {}): string =>
  CATALOG[locale][key].replace(/\{(\w+)\}/g, (m, name: string) => vars[name] ?? m)

export const usd = (locale: Locale, value: number): string =>
  new Intl.NumberFormat(locale, { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value)
