import { initWasm, Resvg } from "@resvg/resvg-wasm"
import satori from "satori"
import { CardFor, type CardVariant } from "./invite-card-variants"

export { CARD_VARIANTS, type CardVariant } from "./invite-card-variants"

/**
 * Per-invite Open Graph image (1200x630 PNG). Shows only the inviter's first name and avatar;
 * never the conversation, the recipient or any secret. Without a card (unknown code, API not
 * ready) it renders the generic invite.
 */
export interface InviteCard {
  readonly first_name: string
  readonly avatar_url?: string | null
}

// The renderer and the fonts ship inside the server function (`virtual:og-runtime`, see
// vite.config.ts), loaded on the first render only. No HTTP self-fetch: that would depend on
// the deployment's protection settings and on the static output.
const bytes = (b64: string): Uint8Array => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))

let ready: Promise<{ bold: Uint8Array; medium: Uint8Array }> | undefined
const assets = () =>
  (ready ??= (async () => {
    const { resvgWasm, inter700, inter500 } = await import("virtual:og-runtime")
    await initWasm(bytes(resvgWasm))
    return { bold: bytes(inter700), medium: bytes(inter500) }
  })().catch((e) => {
    ready = undefined
    throw e
  }))

/** The bundled font covers Latin; other scripts get the generic headline instead of boxes. */
const LATIN = /^[ -ɏ]+$/

/** Shipped design (Lawrence, 2026-10-02): minimal. The others stay behind `?v=` for review. */
export const DEFAULT_CARD_VARIANT: CardVariant = "minimal"

export const renderInviteCard = async (cardIn: InviteCard | null, variant: CardVariant = DEFAULT_CARD_VARIANT, square = false): Promise<Uint8Array> => {
  const { bold, medium } = await assets()
  const card = cardIn && LATIN.test(cardIn.first_name) ? cardIn : cardIn ? { ...cardIn, first_name: "Someone" } : null
  const height = square ? 1200 : 630
  // The square form exists for the minimal design only.
  const svg = await satori(<CardFor variant={square ? "minimal" : variant} card={card} height={height} />, {
    width: 1200,
    height,
    fonts: [
      { name: "Inter", data: bold.buffer as ArrayBuffer, weight: 700, style: "normal" },
      { name: "Inter", data: medium.buffer as ArrayBuffer, weight: 500, style: "normal" }
    ]
  })
  return new Resvg(svg, { fitTo: { mode: "width", value: 1200 } }).render().asPng()
}
