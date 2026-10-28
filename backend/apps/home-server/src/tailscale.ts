/** Who a tailnet peer is (from WhoIs), or why it has no person behind it. */
export type PeerIdentity =
  | { readonly ok: true; readonly login: string; readonly display_name: string; readonly node: string }
  | { readonly ok: false; readonly code: "tagged_node" | "unknown_peer" | "tailscale_unavailable" }

/** This host's tailnet facts (from `tailscale status --json`). */
export interface TailnetSelf {
  readonly addresses: ReadonlyArray<string>
  readonly dns_name: string | null
  readonly login: string | null
  readonly tagged: boolean
}

/** The Tailscale questions the server asks; a fake in tests. */
export interface Tailnet {
  whois(address: string): Promise<PeerIdentity>
  self(): Promise<TailnetSelf>
}

/** Runs a command and returns stdout, or null when it fails. */
type Run = (argv: ReadonlyArray<string>) => Promise<string | null>

const defaultRun: Run = async (argv) => {
  try {
    const p = Bun.spawn([...argv], { stdout: "pipe", stderr: "ignore" })
    const [out, code] = await Promise.all([new Response(p.stdout).text(), p.exited])
    return code === 0 ? out : null
  } catch {
    return null
  }
}

/** The tailscale CLI: macOS app or standalone, Linux package (the CLI handles each LocalAPI transport). */
const tailscaleBinary = (): string => {
  for (const p of ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]) if (Bun.file(p).size > 0) return p
  return "tailscale"
}

/** How long a WhoIs answer is reused for the same peer address. */
const WHOIS_TTL_MS = 60_000

/**
 * WhoIs and self facts through the `tailscale` CLI. A peer with tags has no login and is never a
 * person: it is refused. Answers are cached per address for a minute.
 */
export class TailscaleCli implements Tailnet {
  private readonly cache = new Map<string, { at: number; id: PeerIdentity }>()

  constructor(
    private readonly run: Run = defaultRun,
    private readonly binary: string = tailscaleBinary(),
    private readonly now: () => number = Date.now
  ) {}

  async whois(address: string): Promise<PeerIdentity> {
    const hit = this.cache.get(address)
    if (hit && this.now() - hit.at < WHOIS_TTL_MS) return hit.id
    const out = await this.run([this.binary, "whois", "--json", address])
    const id = out === null ? ({ ok: false, code: "unknown_peer" } as const) : parseWhois(out)
    if (id.ok || id.code !== "tailscale_unavailable") this.cache.set(address, { at: this.now(), id })
    return id
  }

  async self(): Promise<TailnetSelf> {
    const out = await this.run([this.binary, "status", "--json"])
    if (out === null) return { addresses: [], dns_name: null, login: null, tagged: false }
    return parseStatus(out)
  }
}

/** A WhoIs JSON answer as a peer identity. */
export const parseWhois = (text: string): PeerIdentity => {
  let j: { Node?: { Name?: string; Tags?: Array<string> }; UserProfile?: { LoginName?: string; DisplayName?: string } }
  try {
    j = JSON.parse(text.slice(text.indexOf("{")))
  } catch {
    return { ok: false, code: "unknown_peer" }
  }
  if ((j.Node?.Tags ?? []).length > 0) return { ok: false, code: "tagged_node" }
  const login = j.UserProfile?.LoginName
  if (!login || login === "tagged-devices") return { ok: false, code: "tagged_node" }
  return { ok: true, login: login.toLowerCase(), display_name: j.UserProfile?.DisplayName || login, node: (j.Node?.Name ?? "").replace(/\.$/, "") }
}

/** `tailscale status --json` as this host's facts. */
export const parseStatus = (text: string): TailnetSelf => {
  try {
    const j = JSON.parse(text.slice(text.indexOf("{"))) as { Self?: { TailscaleIPs?: Array<string>; DNSName?: string; UserID?: number; Tags?: Array<string> }; User?: Record<string, { LoginName?: string }> }
    const self = j.Self ?? {}
    const login = self.UserID !== undefined ? (j.User?.[String(self.UserID)]?.LoginName ?? null) : null
    const tagged = (self.Tags ?? []).length > 0
    return { addresses: self.TailscaleIPs ?? [], dns_name: self.DNSName ? self.DNSName.replace(/\.$/, "") : null, login: tagged ? null : (login?.toLowerCase() ?? null), tagged }
  } catch {
    return { addresses: [], dns_name: null, login: null, tagged: false }
  }
}

/** Whether `address` is a tailnet address (100.64.0.0/10 or fd7a:115c:a1e0::/48). */
export const isTailnetAddress = (address: string): boolean => {
  const a = address.replace(/^::ffff:/, "").toLowerCase()
  const v4 = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(a)
  if (v4) return Number(v4[1]) === 100 && Number(v4[2]) >= 64 && Number(v4[2]) <= 127
  return a.startsWith("fd7a:115c:a1e0:")
}

/** Whether `address` is loopback. */
export const isLoopback = (address: string): boolean => {
  const a = address.replace(/^::ffff:/, "")
  return a === "::1" || a.startsWith("127.")
}
