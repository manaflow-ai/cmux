import { initWasm, Resvg } from "@resvg/resvg-wasm"
import satori from "satori"
import logo from "./cmux-logo.png?inline"

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

const Avatar = ({ card }: { card: InviteCard }) =>
  card.avatar_url ? (
    <img src={card.avatar_url} width={168} height={168} style={{ borderRadius: 84, border: "6px solid rgba(255,255,255,0.92)", objectFit: "cover" }} />
  ) : (
    <div style={{ width: 168, height: 168, borderRadius: 84, background: "#2563eb", color: "white", fontSize: 84, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center", border: "6px solid rgba(255,255,255,0.92)" }}>
      {card.first_name.slice(0, 1).toUpperCase()}
    </div>
  )

const Card = ({ card }: { card: InviteCard | null }) => (
  <div style={{ width: 1200, height: 630, display: "flex", flexDirection: "column", justifyContent: "space-between", padding: 72, background: "linear-gradient(135deg, #0b1020 0%, #172554 55%, #1e3a8a 100%)", color: "white", fontFamily: "Inter" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
      <img src={logo} width={72} height={72} style={{ borderRadius: 16 }} />
      <div style={{ fontSize: 44, fontWeight: 700, letterSpacing: -1 }}>cmux</div>
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 44 }}>
      {card ? <Avatar card={card} /> : null}
      <div style={{ display: "flex", flexDirection: "column", gap: 14, maxWidth: card ? 820 : 1050 }}>
        <div style={{ fontSize: card ? 68 : 76, fontWeight: 700, lineHeight: 1.08, letterSpacing: -1.5 }}>{card ? `${card.first_name} invited you to chat` : "You're invited to chat on cmux"}</div>
        <div style={{ fontSize: 34, fontWeight: 500, color: "rgba(226,232,240,0.92)" }}>Messages with people and their AI chiefs</div>
      </div>
    </div>
    <div style={{ display: "flex", fontSize: 26, fontWeight: 500, color: "rgba(191,219,254,0.85)" }}>Tap to open your invite</div>
  </div>
)

export const renderInviteCard = async (cardIn: InviteCard | null, origin: string): Promise<Uint8Array> => {
  const { bold, medium } = await assets(origin)
  const card = cardIn && LATIN.test(cardIn.first_name) ? cardIn : cardIn ? { ...cardIn, first_name: "Someone" } : null
  const svg = await satori(<Card card={card} />, {
    width: 1200,
    height: 630,
    fonts: [
      { name: "Inter", data: bold, weight: 700, style: "normal" },
      { name: "Inter", data: medium, weight: 500, style: "normal" }
    ]
  })
  return new Resvg(svg, { fitTo: { mode: "width", value: 1200 } }).render().asPng()
}
