/**
 * The network of a Cloud Chief's turn machine (turn.ts): what the agent user (`chief`, Claude Code) may
 * reach. The VM itself always has Freestyle's public egress (vm.ts, dual-stack IPv4 and IPv6); this is the
 * in-guest nftables table `inet chiefcc` for the agent's uid, applied as root after boot.sh (which leaves
 * the agent closed until then) and again whenever the Chief changes it with `chief-net` (chief-turn-runner).
 *
 * Default (Lawrence, 2026-10-20: "more permissive by default"; 2026-10-21, msg 8200: the tailnet too): the
 * public Internet, DNS and the tailnet (100.64.0.0/10 with its DNS 100.100.100.100, fd7a:115c:a1e0::/48; what
 * the node may reach there is the tailnet policy of its tag, CHIEF_CC_TS_TAG) are open, so git clone, package
 * installs, the Mac gate, the hub and the build controller work; private and link-local addresses and other
 * loopback ports stay closed unless the Chief opens them. Kept per brain (agent/conversation) in cb_config `cc_net`.
 */
export interface CcNet {
  /** Every public IPv4 and IPv6 address (private, link-local and multicast ranges excluded). */
  readonly internet: boolean
  /** DNS to the nameservers in /etc/resolv.conf (with `internet` off, the only lookups allowed). */
  readonly dns: boolean
  /** The tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48), as this VM's node (tag CHIEF_CC_TS_TAG). */
  readonly tailnet: boolean
  /** Every loopback port (off: only the model forward 4017 and the network tool 4018). */
  readonly local: boolean
  /** Hosts or address ranges the agent may reach even with `internet` off. */
  readonly allow: ReadonlyArray<string>
  /** Hosts or address ranges the agent may never reach (checked before everything but the model forward). */
  readonly deny: ReadonlyArray<string>
}

export const CC_NET_DEFAULT: CcNet = { internet: true, dns: true, tailnet: true, local: false, allow: [], deny: [] }
const SWITCHES = ["internet", "dns", "tailnet", "local"] as const
const LISTS = ["allow", "deny"] as const
const MAX_ENTRIES = 64

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/
const HOST = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$/
const isIpv6 = (s: string) => {
  if (!/^[0-9a-f:]+$/.test(s) || s.split("::").length > 2) return false
  const groups = s.split(":").filter((g) => g !== "")
  return groups.every((g) => g.length <= 4) && (s.includes("::") ? groups.length < 8 : groups.length === 8)
}
/** One entry as kept: a lowercase host, an IPv4/IPv6 address, or one with a prefix length; null when it is none. */
const entry = (raw: unknown): string | null => {
  if (typeof raw !== "string") return null
  const s = raw.trim().toLowerCase()
  const [addr, len, ...rest] = s.split("/")
  if (rest.length > 0 || addr === undefined) return null
  const v4 = IPV4.test(addr)
  const v6 = !v4 && isIpv6(addr)
  if (len !== undefined) {
    const max = v4 ? 32 : v6 ? 128 : -1
    return /^\d{1,3}$/.test(len) && Number(len) <= max ? s : null
  }
  return v4 || v6 || HOST.test(addr) ? s : null
}

/** A patch (the `chief-net` tool's PUT body) applied to `current`: switches as booleans, lists replaced whole, `reset` back to the default. */
export const patchNet = (current: CcNet, patch: unknown): { ok: true; net: CcNet } | { ok: false; error: string } => {
  if (patch === null || typeof patch !== "object" || Array.isArray(patch)) return { ok: false, error: "the network patch must be an object" }
  const p = patch as Record<string, unknown>
  const unknown = Object.keys(p).find((k) => k !== "reset" && !(SWITCHES as ReadonlyArray<string>).includes(k) && !(LISTS as ReadonlyArray<string>).includes(k))
  if (unknown) return { ok: false, error: `unknown network setting ${unknown} (settings: ${[...SWITCHES, ...LISTS].join(", ")}, reset)` }
  const next: { -readonly [K in keyof CcNet]: CcNet[K] } = p.reset === true ? { ...CC_NET_DEFAULT } : { ...current }
  for (const k of SWITCHES) {
    if (p[k] === undefined) continue
    if (typeof p[k] !== "boolean") return { ok: false, error: `${k} must be true or false` }
    next[k] = p[k]
  }
  for (const k of LISTS) {
    if (p[k] === undefined) continue
    const list = p[k]
    if (!Array.isArray(list)) return { ok: false, error: `${k} must be a list of hosts or address ranges` }
    if (list.length > MAX_ENTRIES) return { ok: false, error: `${k} holds at most ${MAX_ENTRIES} entries` }
    const out: Array<string> = []
    for (const raw of list) {
      const e = entry(raw)
      if (e === null) return { ok: false, error: `${k}: ${JSON.stringify(raw).slice(0, 80)} is not a host name, an IP address or an address range` }
      if (!out.includes(e)) out.push(e)
    }
    next[k] = out
  }
  return { ok: true, net: next }
}

/** The kept settings (cb_config `cc_net`), or the default when there are none or they no longer read. */
export const readNet = (raw: string | undefined): CcNet => {
  if (!raw) return CC_NET_DEFAULT
  try {
    const r = patchNet(CC_NET_DEFAULT, JSON.parse(raw))
    return r.ok ? r.net : CC_NET_DEFAULT
  } catch {
    return CC_NET_DEFAULT
  }
}

const PRIVATE_V4 = "0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4"
const PRIVATE_V6 = "::/128, ::1/128, ::ffff:0:0/96, fc00::/7, fe80::/10, ff00::/8"

/**
 * The root script (`bash -s`) that replaces the agent's table in one nftables transaction and prints
 * "net ok". Hosts are resolved by root when it runs (an unresolvable host is skipped and named on
 * stderr). Every entry passed `entry`, so it is safe inside single quotes. Rules, first match wins: the
 * model forward and the network tool; `local`; `deny`; DNS; `allow`; the tailnet; the Internet; reject.
 */
export const netScript = (net: CcNet): string => {
  const q = (xs: ReadonlyArray<string>) => xs.map((x) => `'${x}'`).join(" ")
  const lines = [
    "set -euo pipefail",
    'uid="$(id -u chief)"',
    "install -d -m 700 /run/chief",
    "v4=(); v6=()",
    "# split ENTRY... into the v4 and v6 arrays; a host becomes its current addresses",
    "split() { v4=(); v6=(); local e a x; for e in \"$@\"; do",
    "  if [[ \"$e\" == *:* ]]; then v6+=(\"$e\"); elif [[ \"$e\" =~ ^[0-9./]+$ ]]; then v4+=(\"$e\")",
    "  else a=\"$(getent ahosts \"$e\" | awk '{print $1}' | sort -u || true)\"; [[ -n \"$a\" ]] || echo \"chief-net: $e does not resolve; skipped\" >&2",
    "    for x in $a; do if [[ \"$x\" == *:* ]]; then v6+=(\"$x\"); else v4+=(\"$x\"); fi; done; fi; done; }",
    "join() { local IFS=,; echo \"$*\"; }",
    "# rule VERB: VERB for the agent to every address in v4 and v6",
    "rule() { [[ ${#v4[@]} -eq 0 ]] || echo \"    meta skuid $uid ip daddr { $(join \"${v4[@]}\") } $1\"; [[ ${#v6[@]} -eq 0 ]] || echo \"    meta skuid $uid ip6 daddr { $(join \"${v6[@]}\") } $1\"; }",
    "{",
    "  echo 'add table inet chiefcc'",
    "  echo 'delete table inet chiefcc'",
    "  echo 'table inet chiefcc {'",
    "  echo '  chain out {'",
    "  echo '    type filter hook output priority 0; policy accept;'",
    "  echo \"    meta skuid $uid oif lo ip daddr 127.0.0.1 tcp dport { 4017, 4018 } accept\"",
    net.local ? "  echo \"    meta skuid $uid oif lo accept\"" : "",
    net.deny.length ? `  split ${q(net.deny)}; rule reject` : "",
    net.dns
      ? "  split $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); rule \"udp dport 53 accept\"; rule \"tcp dport 53 accept\""
      : "  echo \"    meta skuid $uid meta l4proto { tcp, udp } th dport 53 reject\"",
    net.allow.length ? `  split ${q(net.allow)}; rule accept` : "",
    net.tailnet ? "  echo \"    meta skuid $uid ip daddr 100.64.0.0/10 accept\"; echo \"    meta skuid $uid ip6 daddr fd7a:115c:a1e0::/48 accept\"" : "",
    net.internet
      ? [
          `  echo "    meta skuid $uid ip daddr { ${PRIVATE_V4} } reject"`,
          `  echo "    meta skuid $uid ip6 daddr { ${PRIVATE_V6} } reject"`,
          '  echo "    meta skuid $uid accept"'
        ].join("\n")
      : "",
    "  echo \"    meta skuid $uid counter reject\"",
    "  echo '  }'",
    "  echo '}'",
    "} > /run/chief/net.nft",
    "nft -f /run/chief/net.nft",
    "echo net ok"
  ]
  return `${lines.filter(Boolean).join("\n")}\n`
}
