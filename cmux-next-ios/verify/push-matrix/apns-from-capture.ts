// Turns what the real Mac host posted to /notify (notify-tap.mjs JSON lines) into the
// exact APNs bodies the Worker sends, with the Worker's own parseNotify and apnsPayload.
//   node apns-from-capture.ts CAPTURE.jsonl OUTDIR MAC_NAME [--no-previews] [--phone DEVICE_ID]
// With --phone, an event the Mac sealed for that phone gives the Worker's sealed payload.
// Writes OUTDIR/<n>-<kind>-<eventId>.json (one per event) and prints their names.
import fs from "node:fs"
import path from "node:path"
import { apnsPayload, parseNotify, sealedPayload } from "../../backend/src/push.ts"

const [capture, outDir, macName, ...rest] = process.argv.slice(2)
const flag = rest.includes("--no-previews") ? "--no-previews" : undefined
const phone = rest.includes("--phone") ? rest[rest.indexOf("--phone") + 1]?.toLowerCase() : undefined
fs.mkdirSync(outDir, { recursive: true })
const lines = fs.readFileSync(capture, "utf8").split("\n").filter(Boolean)
lines.forEach((line, i) => {
  const { mac, event } = JSON.parse(line)
  const parsed = parseNotify(event)
  if (typeof parsed === "string") return console.error(`skip ${i}: ${parsed}`)
  const e = { ...parsed, macId: mac, macName }
  const box = phone ? e.sealed?.[phone] : undefined
  const payload = box ? sealedPayload(e, box, { previews: flag !== "--no-previews" }) : apnsPayload(e, { previews: flag !== "--no-previews" })
  const name = `${String(i).padStart(2, "0")}-${parsed.kind}-${parsed.eventId}.json`.replace(/[^A-Za-z0-9._-]/g, "_")
  fs.writeFileSync(path.join(outDir, name), JSON.stringify(payload, null, 1))
  console.log(name, Buffer.byteLength(JSON.stringify(payload)))
})
