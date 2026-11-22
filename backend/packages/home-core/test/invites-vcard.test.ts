import { describe, expect, it } from "vitest"
import { foldLine, renderVCard, vCardLines } from "../src/invites/vcard.ts"

const photo = Buffer.from(Uint8Array.from({ length: 600 }, (_, i) => (i * 37) % 256)).toString("base64")

describe("contact card", () => {
  it("renders a valid vCard 3.0 with CRLF lines folded at 75 octets", () => {
    const text = renderVCard({ name: "Chief · cmux", organization: "cmux", phone: "+14155550199", url: "https://cmux.com", photoJpegBase64: photo })
    expect(text.startsWith("BEGIN:VCARD\r\nVERSION:3.0\r\n")).toBe(true)
    expect(text.endsWith("END:VCARD\r\n")).toBe(true)
    for (const raw of text.split("\r\n")) expect(new TextEncoder().encode(raw).length).toBeLessThanOrEqual(75)
    const lines = vCardLines(text)
    expect(lines).toContain("FN:Chief · cmux")
    expect(lines).toContain("TEL;TYPE=CELL,VOICE,pref:+14155550199")
    expect(lines).toContain("URL;TYPE=WORK:https://cmux.com")
    expect(lines.find((l) => l.startsWith("PHOTO;ENCODING=b;TYPE=JPEG:"))?.slice(27)).toBe(photo)
  })

  it("escapes text values and refuses bad input", () => {
    expect(vCardLines(renderVCard({ name: "a,b;c", phone: "+14155550199", url: "https://cmux.com" }))).toContain("FN:a\\,b\;c")
    expect(() => renderVCard({ name: "cmux", phone: "4155550199", url: "https://cmux.com" })).toThrow()
    expect(() => renderVCard({ name: "cmux", phone: "+14155550199", url: "http://cmux.com" })).toThrow()
    expect(() => renderVCard({ name: " ", phone: "+14155550199", url: "https://cmux.com" })).toThrow()
  })

  it("folds multi-byte text without splitting a character", () => {
    const folded = foldLine(`NOTE:${"·".repeat(80)}`)
    expect(folded.replace(/\r\n /g, "")).toBe(`NOTE:${"·".repeat(80)}`)
  })
})
