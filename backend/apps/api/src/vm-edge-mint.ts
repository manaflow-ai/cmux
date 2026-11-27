import { platformRead } from "./platform-api.ts"
import type { Env } from "./env.ts"

/**
 * T17 (goal cloud-machine-no-plaintext-secrets): a Cloud machine's install key, copied off the machine by an agent with
 * sudo, must not mint a cmux token elsewhere. A machine whose own routes accept its platform edge (cmux-platform
 * PlatformEdge) signs in through the edge, which injects its identity and never hands the guest a key; so once the
 * platform says so for that machine, a `vm` install's own key no longer mints at POST /v1/auth/token.
 *
 * The platform says so on the same read cmux-api already uses for a VM's machine (cloud.vm.self.get, as
 * github-token-route.ts reads `platform_edge`), with `edge_signin: true`. That field is separate from `platform_edge`
 * (the machine's git goes through the edge): a machine's git can be on the edge before its daemon signs in through it,
 * and refusing the key then would cut the daemon off. Without the field (every machine today, production has no edge
 * signing key) nothing changes.
 *
 * The read is made as the token just minted, which never leaves this Worker when refused. A read that fails (no
 * PLATFORM binding, an outage, the machine gone) keeps today's answer: the machine routes behind the platform refuse
 * on their own gate, and a platform outage must not stop every machine from signing in.
 */
export type EdgeMintCheck = { readonly refused: false } | { readonly refused: true; readonly message: string }

export const EDGE_SIGNIN_REFUSAL = "this machine signs in through its platform edge; its install key does not mint a token"

export const vmEdgeMintCheck = async (
  env: Pick<Env, "PLATFORM">,
  origin: string,
  minted: { readonly vm?: true; readonly bound_machine?: string },
  token: string
): Promise<EdgeMintCheck> => {
  if (minted.vm !== true || !minted.bound_machine || !env.PLATFORM) return { refused: false }
  const self = await platformRead(env.PLATFORM, origin, `Bearer ${token}`, "cloud.vm.self.get", { machine: minted.bound_machine })
  if (!self.ok) {
    if (self.retryable) console.error(JSON.stringify({ msg: "vm mint edge check unreachable", code: self.code, message: self.message.slice(0, 200) }))
    return { refused: false }
  }
  const edged = (self.value as { edge_signin?: unknown } | null)?.edge_signin === true
  if (edged) console.log(JSON.stringify({ msg: "vm install-key mint refused: machine signs in through its edge", machine: minted.bound_machine }))
  return edged ? { refused: true, message: EDGE_SIGNIN_REFUSAL } : { refused: false }
}
