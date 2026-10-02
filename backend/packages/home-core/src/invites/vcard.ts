/**
 * The cmux contact card sent before the first text to a number (decision A,
 * home-messaging.md section 15): once the recipient saves it, message apps
 * load link previews from cmux, and the person can text Chief directly.
 * vCard 3.0, which phone contact apps import with an embedded photo
 * (PHOTO;ENCODING=b): a photo given only by URL is not shown by most
 * contact apps. Lines end in CRLF and fold at 75 octets.
 */
export interface CardInput {
  /** Display name, for example "cmux" or "Chief · cmux". */
  readonly name: string
  readonly organization?: string
  /** E.164 number of the sending line. */
  readonly phone: string
  readonly url: string
  /** JPEG bytes for PHOTO, base64 (no line breaks). Keep the image small (about 20 KB). */
  readonly photoJpegBase64?: string
  readonly note?: string
}

/** Escapes a vCard 3.0 text value (RFC 2426 section 4). */
export const escapeVCardText = (value: string): string =>
  value.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/,/g, "\\,").replace(/;/g, "\;")

/** Folds one content line at 75 octets (UTF-8 safe): continuation lines start with one space. */
export const foldLine = (line: string): string => {
  const bytes = new TextEncoder().encode(line)
  if (bytes.length <= 75) return line
  const out: Array<string> = []
  let current = ""
  let size = 0
  for (const ch of line) {
    const n = new TextEncoder().encode(ch).length
    const limit = out.length === 0 ? 75 : 74
    if (size + n > limit) {
      out.push(current)
      current = ""
      size = 0
    }
    current += ch
    size += n
  }
  out.push(current)
  return out.join("\r\n ")
}

export const renderVCard = (card: CardInput): string => {
  if (!/^\+[1-9][0-9]{7,14}$/.test(card.phone)) throw new Error("card phone must be E.164")
  if (!/^https:\/\/[^\s]+$/.test(card.url)) throw new Error("card url must be an absolute https URL")
  if (card.photoJpegBase64 !== undefined && !/^[A-Za-z0-9+/]+=*$/.test(card.photoJpegBase64)) throw new Error("photo must be base64 without line breaks")
  const name = escapeVCardText(card.name.trim())
  if (!name) throw new Error("card name is empty")
  const lines = [
    "BEGIN:VCARD",
    "VERSION:3.0",
    `FN:${name}`,
    `N:;${name};;;`,
    ...(card.organization ? [`ORG:${escapeVCardText(card.organization)}`] : []),
    `TEL;TYPE=CELL,VOICE,pref:${card.phone}`,
    `URL;TYPE=WORK:${card.url}`,
    ...(card.note ? [`NOTE:${escapeVCardText(card.note)}`] : []),
    ...(card.photoJpegBase64 ? [`PHOTO;ENCODING=b;TYPE=JPEG:${card.photoJpegBase64}`] : []),
    "END:VCARD"
  ]
  return `${lines.map(foldLine).join("\r\n")}\r\n`
}

/** Unfolds and splits a card back into content lines (tests and validation). */
export const vCardLines = (text: string): Array<string> => text.replace(/\r\n[ \t]/g, "").split("\r\n").filter(Boolean)
