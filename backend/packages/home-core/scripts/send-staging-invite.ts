/**
 * Sends one staging invite through the real send path (deliverInvite with
 * environment "staging"), to allow-list entry N. Addresses never appear on
 * the command line or in the output; only the entry number does.
 *
 *   HOME_INVITE_ALLOWLIST_FILE=<private file> RESEND_API_KEY=… SENDBLUE_API_KEY=… \
 *   SENDBLUE_API_SECRET=… SENDBLUE_FROM_NUMBER=… bun scripts/send-staging-invite.ts <entry> <A|B|C> [render]
 *
 * With `render`, it prints the exact text (subject and body) and sends nothing:
 * report that text before every send.
 *
 * The allow-list file holds `email <address>` / `phone <number>` lines and
 * lives outside the repository. Anything outside it is refused before the
 * provider call (sender.ts), exactly as in the staging Worker.
 */
import { randomBytes } from "node:crypto"
import { readFileSync } from "node:fs"
import { deliverInvite, inviteLink, newInviteSecret, parseAllowlist, renderEmail, renderSms, type Variant } from "../src/invites/index.ts"

const [entryArg, variantArg = "A", mode] = process.argv.slice(2)
const entry = Number(entryArg)
const file = process.env.HOME_INVITE_ALLOWLIST_FILE
if (!file || !Number.isInteger(entry) || entry < 1 || !["A", "B", "C"].includes(variantArg)) {
  console.error("usage: HOME_INVITE_ALLOWLIST_FILE=<file> bun scripts/send-staging-invite.ts <entry 1..n> <A|B|C>")
  process.exit(2)
}
const allowlist = parseAllowlist(readFileSync(file, "utf8"))
const address = allowlist.entries[entry - 1]
if (!address) {
  console.error(`allow list has ${allowlist.entries.length} entries; no entry ${entry}`)
  process.exit(2)
}
const need = (name: string) => {
  const v = process.env[name]
  if (!v) throw new Error(`${name} is not set`)
  return v
}

const conversation = `conv_dm_${newInviteSecret(randomBytes(16))}`
const link = inviteLink("staging", conversation, newInviteSecret(randomBytes(16)))
const copy = {
  variant: variantArg as Variant,
  locale: "en" as const,
  inviterName: "Lawrence",
  trustedInviter: true,
  kind: "dm" as const,
  preview: "want to try my agents? (staging test of the cmux invite)",
  link,
  // The unsubscribe and report routes are not built yet: no footer links rather than dead ones.
  firstSmsToNumber: true
}
const message = address.channel === "email" ? renderEmail(copy) : renderSms(copy)
const staged =
  message.channel === "email" ? { ...message, subject: `[staging] ${message.subject}` } : { ...message, body: `[staging] ${message.body}` }
if (mode === "render") {
  // The secret never goes to a terminal or a report: the fragment is masked.
  const mask = (text: string) => text.replace(/#[0-9A-HJKMNP-TV-Z]{26}/g, "#<secret>")
  console.log(JSON.stringify({ channel: staged.channel, entry, variant: staged.variant, ...(staged.channel === "email" ? { subject: staged.subject, text: mask(staged.text) } : { body: mask(staged.body) }) }, null, 2))
  process.exit(0)
}
const inviteId = `inv_staging_${newInviteSecret(randomBytes(16))}`
const result = await deliverInvite(
  {
    policy: { environment: "staging", allowlist, sendSwitch: process.env.HOME_INVITES_SEND },
    fetch: (url, init) => fetch(url, init),
    ...(address.channel === "email"
      ? { resend: { apiKey: need("RESEND_API_KEY"), from: process.env.HOME_INVITE_FROM ?? "cmux <invites@cmux.com>" } }
      : { sendblue: { apiKeyId: need("SENDBLUE_API_KEY"), apiSecret: need("SENDBLUE_API_SECRET"), fromNumber: need("SENDBLUE_FROM_NUMBER") } })
  },
  { inviteId, address, suppression: null, message: staged }
)
const reason = result.reason?.split(address.value).join("<recipient>")
console.log(JSON.stringify({ at: new Date().toISOString(), channel: result.channel, entry, variant: message.variant, state: result.state, provider_id: result.provider_id ?? null, http_status: result.http_status ?? null, reason: reason ?? null }))
