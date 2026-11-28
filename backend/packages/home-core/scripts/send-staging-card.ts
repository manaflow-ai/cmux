/**
 * First contact on the text channel (decision A): the cmux contact card, then
 * the invite text with the link alone on the last line. Staging only, to one
 * allow-list entry by number; the environment policy runs before any
 * provider call. Addresses never appear on the command line or in the output.
 *
 *   HOME_INVITE_ALLOWLIST_FILE=<private file> SENDBLUE_API_KEY=… SENDBLUE_API_SECRET=… \
 *   SENDBLUE_FROM_NUMBER=… bun scripts/send-staging-card.ts <entry> <cmux|chief> [render]
 */
import { randomBytes } from "node:crypto"
import { readFileSync } from "node:fs"
import { decideSend, deliverInvite, inviteLink, newInviteSecret, parseAllowlist, renderSms, renderVCard, vCardLines } from "../src/invites/index.ts"

const [entryArg, nameArg = "cmux", mode] = process.argv.slice(2)
const NAMES: Record<string, { name: string; organization?: string }> = { cmux: { name: "cmux" }, chief: { name: "Chief · cmux", organization: "cmux" } }
const entry = Number(entryArg)
const file = process.env.HOME_INVITE_ALLOWLIST_FILE
const choice = NAMES[nameArg]
if (!file || !Number.isInteger(entry) || entry < 1 || !choice) {
  console.error("usage: bun scripts/send-staging-card.ts <entry> <cmux|chief> [render]")
  process.exit(2)
}
const allowlist = parseAllowlist(readFileSync(file, "utf8"))
const address = allowlist.entries[entry - 1]
if (!address || address.channel !== "sms") {
  console.error(`entry ${entry} is not a phone on the allow list`)
  process.exit(2)
}
const fromNumber = process.env.SENDBLUE_FROM_NUMBER ?? "+10000000000"
const photo = readFileSync(new URL("../assets/contact-photo.jpg", import.meta.url)).toString("base64")
const card = renderVCard({ ...choice, phone: fromNumber, url: "https://cmux.com", photoJpegBase64: photo })
const link = inviteLink("staging", `conv_dm_${newInviteSecret(randomBytes(16))}`, newInviteSecret(randomBytes(16)))
const sms = renderSms({
  variant: "A",
  locale: "en",
  inviterName: "Lawrence",
  trustedInviter: true,
  kind: "dm",
  preview: "want to try my agents? (staging test of the cmux invite)",
  link,
  firstSmsToNumber: true
})
const body = `[staging] ${sms.body}`
const mask = (t: string) => t.replace(/#[0-9A-HJKMNP-TV-Z]{26}/g, "#<secret>")
const cardSummary = vCardLines(card).map((l) => (l.startsWith("PHOTO") ? `PHOTO;ENCODING=b;TYPE=JPEG:<${photo.length} base64 chars>` : l.startsWith("TEL") ? "TEL;TYPE=CELL,VOICE,pref:<sending line>" : l))

if (mode === "render") {
  console.log(JSON.stringify({ entry, card: cardSummary, card_bytes: card.length, text: mask(body) }, null, 2))
  process.exit(0)
}

const decision = decideSend({ environment: "staging", allowlist, sendSwitch: process.env.HOME_INVITES_SEND }, address, null)
if (!decision.send) {
  console.log(JSON.stringify({ entry, state: decision.state, reason: decision.reason }))
  process.exit(1)
}
const need = (name: string) => {
  const v = process.env[name]
  if (!v) throw new Error(`${name} is not set`)
  return v
}
const headers = { "sb-api-key-id": need("SENDBLUE_API_KEY"), "sb-api-secret-key": need("SENDBLUE_API_SECRET") }
const form = new FormData()
form.append("file", new Blob([card], { type: "text/vcard" }), "cmux.vcf")
const upload = await fetch("https://api.sendblue.com/api/upload-file", { method: "POST", headers, body: form })
const uploaded = (await upload.json().catch(() => ({}))) as { media_url?: string }
if (!upload.ok || !uploaded.media_url || !/\.(vcf|vcard)$/.test(uploaded.media_url) || /\s/.test(uploaded.media_url)) {
  console.log(JSON.stringify({ entry, step: "upload", http_status: upload.status, ok: false }))
  process.exit(1)
}
const cardSend = await fetch("https://api.sendblue.com/api/send-message", {
  method: "POST",
  headers: { ...headers, "Content-Type": "application/json" },
  body: JSON.stringify({ number: address.value, from_number: need("SENDBLUE_FROM_NUMBER"), media_url: uploaded.media_url })
})
const cardReply = (await cardSend.json().catch(() => ({}))) as { message_handle?: string; status?: string }
console.log(JSON.stringify({ at: new Date().toISOString(), step: "card", entry, http_status: cardSend.status, provider_id: cardReply.message_handle ?? null, status: cardReply.status ?? null }))
if (!cardSend.ok) process.exit(1)
const result = await deliverInvite(
  {
    policy: { environment: "staging", allowlist, sendSwitch: process.env.HOME_INVITES_SEND },
    fetch: (url, init) => fetch(url, init),
    sendblue: { apiKeyId: headers["sb-api-key-id"], apiSecret: headers["sb-api-secret-key"], fromNumber: need("SENDBLUE_FROM_NUMBER") }
  },
  { inviteId: `inv_staging_${newInviteSecret(randomBytes(16))}`, address, suppression: null, message: { ...sms, body } }
)
console.log(JSON.stringify({ at: new Date().toISOString(), step: "text", entry, state: result.state, provider_id: result.provider_id ?? null, http_status: result.http_status ?? null }))
