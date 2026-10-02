import { initWasm, Resvg } from "@resvg/resvg-wasm"
import satori from "satori"
import { CardFor, type CardVariant } from "./invite-card-variants"

export { CARD_VARIANTS, type CardVariant } from "./invite-card-variants"

/**
 * Per-invite Open Graph image (1200x630 PNG). Shows only the inviter's first name and avatar;
 * never the conversation, the recipient or any secret. Without a card (unknown code, API not
 * ready) it renders the generic invite. The WASM renderer and the fonts are static assets of
 * this site, fetched once per server instance from the request's origin.
 */
export interface InviteCard {
  readonly first_name: string
  readonly avatar_url?: string | null
}

let ready: Promise<{ bold: ArrayBuffer; medium: ArrayBuffer }> | undefined
const assets = (origin: string) =>
  (ready ??= (async () => {
    const get = async (path: string) => {
      const res = await fetch(new URL(path, origin))
      if (!res.ok) throw new Error(`asset ${path}: ${res.status}`)
      return res.arrayBuffer()
    }
    // Static copies made by scripts/copy-og-assets.ts (fixed names, pinned package versions).
    const [wasm, bold, medium] = await Promise.all([get("/og/runtime/resvg.wasm"), get("/og/runtime/inter-700.woff"), get("/og/runtime/inter-500.woff")])
    await initWasm(wasm)
    return { bold, medium }
  })().catch((e) => {
    ready = undefined
    throw e
  }))

/** The bundled font covers Latin; other scripts get the generic headline instead of boxes. */
const LATIN = /^[ -ɏ]+$/

export const renderInviteCard = async (cardIn: InviteCard | null, origin: string, variant: CardVariant = "conversation"): Promise<Uint8Array> => {
  const { bold, medium } = await assets(origin)
  const card = cardIn && LATIN.test(cardIn.first_name) ? cardIn : cardIn ? { ...cardIn, first_name: "Someone" } : null
  const svg = await satori(<CardFor variant={variant} card={card} />, {
    width: 1200,
    height: 630,
    fonts: [
      { name: "Inter", data: bold, weight: 700, style: "normal" },
      { name: "Inter", data: medium, weight: 500, style: "normal" }
    ]
  })
  return new Resvg(svg, { fitTo: { mode: "width", value: 1200 } }).render().asPng()
}
