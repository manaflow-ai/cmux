// Turns what the real Mac host posted to /notify (notify-tap.mjs JSON lines) into the
// exact APNs bodies the Worker sends, with the Worker's own parseNotify and apnsPayload.
//   node apns-from-capture.ts CAPTURE.jsonl OUTDIR MAC_NAME [--no-previews]
// Writes OUTDIR/<n>-<kind>-<eventId>.json (one per event) and prints their names.
import fs from "node:fs"
import path from "node:path"
import { apnsPayload, parseNotify } from "../../backend/src/push.ts"

const [capture, outDir, macName, flag] = process.argv.slice(2)
fs.mkdirSync(outDir, { recursive: true })
const lines = fs.readFileSync(capture, "utf8").split("\n").filter(Boolean)
lines.forEach((line, i) => {
  const { mac, event } = JSON.parse(line)
  const parsed = parseNotify(event)
  if (typeof parsed === "string") return console.error(`skip ${i}: ${parsed}`)
  const payload = apnsPayload({ ...parsed, macId: mac, macName }, { previews: flag !== "--no-previews" })
  const name = `${String(i).padStart(2, "0")}-${parsed.kind}-${parsed.eventId}.json`.replace(/[^A-Za-z0-9._-]/g, "_")
  fs.writeFileSync(path.join(outDir, name), JSON.stringify(payload, null, 1))
  console.log(name, Buffer.byteLength(JSON.stringify(payload)))
})
