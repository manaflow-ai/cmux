/**
 * Invite copy (home-messaging.md section 15, decision D-H8). Placeholders:
 * {name} inviter, {preview} the inviter's own words (variant A, trusted
 * inviters only), {title} group title, {link}. English is reviewed; Japanese
 * is a first translation that needs review. Keep SMS bodies short: a GSM SMS
 * segment is 160 characters and a link is about 75.
 */
export type Locale = "en" | "ja"
export type Variant = "A" | "B" | "C"

export interface VariantStrings {
  readonly smsDm: string
  readonly smsGroup: string
  readonly subjectDm: string
  readonly subjectGroup: string
  readonly leadDm: string
  readonly leadGroup: string
}

export interface LocaleStrings {
  readonly variants: Readonly<Record<Variant, VariantStrings>>
  readonly smsOptOut: string
  readonly button: string
  readonly what: string
  readonly why: string
  readonly whyWithEmail: string
  readonly unsubscribe: string
  readonly report: string
  readonly anonymous: string
  readonly untitledGroup: string
  readonly linkRemoved: string
}

export const STRINGS: Readonly<Record<Locale, LocaleStrings>> = {
  en: {
    variants: {
      A: {
        smsDm: `{name} sent you a message on cmux: "{preview}" Reply here: {link}`,
        smsGroup: `{name} sent you a message in "{title}" on cmux: "{preview}" Reply here: {link}`,
        subjectDm: "{name}: {preview}",
        subjectGroup: "{name} in {title}: {preview}",
        leadDm: "{name} sent you a message on cmux.",
        leadGroup: `{name} sent you a message in "{title}" on cmux.`
      },
      B: {
        smsDm: "{name} invited you to chat on cmux, the app where their AI agents report in. Join: {link}",
        smsGroup: `{name} added you to "{title}" on cmux, the app where their AI agents report in. Join: {link}`,
        subjectDm: "{name} invited you to chat on cmux",
        subjectGroup: "{name} added you to {title} on cmux",
        leadDm: "{name} invited you to chat on cmux.",
        leadGroup: `{name} added you to "{title}" on cmux.`
      },
      C: {
        smsDm: "{name} wants to talk with you on cmux. {link}",
        smsGroup: `{name} wants you in "{title}" on cmux. {link}`,
        subjectDm: "{name} wants you on cmux",
        subjectGroup: "{name} wants you in {title}",
        leadDm: "{name} wants to talk with you on cmux.",
        leadGroup: `{name} wants you in "{title}" on cmux.`
      }
    },
    smsOptOut: "Reply STOP to opt out.",
    button: "Open the conversation",
    what: "cmux is where people and their AI agents work together: chiefs that run coding agents on your machines and report back here.",
    why: "{name} entered your address in cmux.",
    whyWithEmail: "{name} ({email}) entered your address in cmux.",
    unsubscribe: "Stop all invites to this address",
    report: "Report spam",
    anonymous: "Someone",
    untitledGroup: "a group",
    linkRemoved: "(link removed)"
  },
  ja: {
    variants: {
      A: {
        smsDm: "{name}さんからcmuxでメッセージが届いています:「{preview}」返信はこちら: {link}",
        smsGroup: "{name}さんから「{title}」でメッセージが届いています:「{preview}」返信はこちら: {link}",
        subjectDm: "{name}さん: {preview}",
        subjectGroup: "{name}さん（{title}）: {preview}",
        leadDm: "{name}さんからcmuxでメッセージが届いています。",
        leadGroup: "{name}さんから「{title}」でメッセージが届いています。"
      },
      B: {
        smsDm: "{name}さんがcmuxでのチャットに招待しています。AIエージェントが報告を届けるアプリです。参加: {link}",
        smsGroup: "{name}さんがcmuxの「{title}」にあなたを追加しました。AIエージェントが報告を届けるアプリです。参加: {link}",
        subjectDm: "{name}さんからcmuxのチャットへの招待",
        subjectGroup: "{name}さんがcmuxの{title}にあなたを追加しました",
        leadDm: "{name}さんがcmuxでのチャットに招待しています。",
        leadGroup: "{name}さんがcmuxの「{title}」にあなたを追加しました。"
      },
      C: {
        smsDm: "{name}さんがcmuxで話したいそうです。{link}",
        smsGroup: "{name}さんが「{title}」に招待しています。{link}",
        subjectDm: "{name}さんがcmuxに招待しています",
        subjectGroup: "{name}さんが{title}に招待しています",
        leadDm: "{name}さんがcmuxで話したいそうです。",
        leadGroup: "{name}さんが「{title}」に招待しています。"
      }
    },
    smsOptOut: "配信停止はSTOPと返信してください。",
    button: "会話を開く",
    what: "cmuxは人とAIエージェントが一緒に働く場所です。チーフがあなたのマシンでコーディングエージェントを動かし、ここに報告します。",
    why: "{name}さんがcmuxであなたのアドレスを入力しました。",
    whyWithEmail: "{name}さん（{email}）がcmuxであなたのアドレスを入力しました。",
    unsubscribe: "このアドレスへの招待をすべて停止",
    report: "迷惑メールとして報告",
    anonymous: "cmuxのユーザー",
    untitledGroup: "グループ",
    linkRemoved: "（リンクを削除しました）"
  }
}
