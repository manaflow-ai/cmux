import { createHash } from "node:crypto"
import type { Principal } from "@cmux/ownership"
import { personalTeamIdFor } from "../../api/src/domains/user.ts"
import { isLoopback, isTailnetAddress, type Tailnet } from "./tailscale.ts"

/** Who may use this server: the owner login and an explicit allow list (remote-hosts.md section 6). */
export interface AccessConfig {
  readonly owner: string
  readonly allow: ReadonlyArray<string>
}

/** An admitted person: the Tailscale login and the principal the owners see. */
export interface Admitted {
  readonly ok: true
  readonly login: string
  readonly display_name: string
  readonly principal: Principal
}

/** Why a connection was refused; the peer learns only `not_allowed`. */
export type Refused = { readonly ok: false; readonly code: "not_allowed"; readonly reason: "not_tailnet" | "self_address" | "tagged_node" | "unknown_peer" | "not_in_allow_list" | "tailscale_unavailable" }

/** The cmux user id of a Tailscale login: stable on every server, so a DM between two logins has one id. */
export const userIdForLogin = (login: string) => `user_${createHash("sha256").update(`tailscale:${login.toLowerCase()}`).digest("hex").slice(0, 20)}`

/** The principal a login acts as: a signed-in human session whose verified email is the login. */
export const principalForLogin = (login: string, displayName: string): Principal => {
  const user = userIdForLogin(login)
  return {
    kind: "session",
    identity: `session:${user}`,
    user,
    team: personalTeamIdFor(user),
    // The identity provider's user id: on a server that is Tailscale (UserDO records it at user.ensure).
    stack_user_id: `tailscale:${login.toLowerCase()}`,
    email: login.toLowerCase(),
    // Tailscale verified the login (an identity provider sign-in); invites bind to it.
    email_verified: true,
    display_name: displayName
  }
}

/**
 * Admission per request: loopback is the owner (a same-host client); a tailnet peer is identified by
 * WhoIs and admitted when its login is the owner or in the allow list. Tagged nodes, the host's own
 * tailnet addresses (another OS user on this host) and any non-tailnet address are refused.
 */
export class Admission {
  constructor(
    private readonly tailnet: Tailnet,
    private readonly access: () => AccessConfig,
    private readonly ownAddresses: () => ReadonlyArray<string>,
    private readonly ownerName: () => string = () => access().owner
  ) {}

  async admit(peer: string): Promise<Admitted | Refused> {
    const access = this.access()
    if (isLoopback(peer)) return this.admitted(access.owner, this.ownerName())
    const address = peer.replace(/^::ffff:/, "")
    if (!isTailnetAddress(address)) return { ok: false, code: "not_allowed", reason: "not_tailnet" }
    if (this.ownAddresses().includes(address)) return { ok: false, code: "not_allowed", reason: "self_address" }
    const who = await this.tailnet.whois(address)
    if (!who.ok) return { ok: false, code: "not_allowed", reason: who.code }
    const allowed = who.login === access.owner.toLowerCase() || access.allow.some((l) => l.toLowerCase() === who.login)
    if (!allowed) return { ok: false, code: "not_allowed", reason: "not_in_allow_list" }
    return this.admitted(who.login, who.display_name)
  }

  private admitted(login: string, name: string): Admitted {
    return { ok: true, login: login.toLowerCase(), display_name: name, principal: principalForLogin(login, name) }
  }
}
