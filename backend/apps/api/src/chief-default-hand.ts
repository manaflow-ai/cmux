import type { Env } from "./env.ts"
import { handStub } from "./hand-api.ts"
import { shellQuote } from "./cloud-acpmux-guest.ts"

/** The P2 binding needed to reach the current VM carrier of a user's default machine. */
export interface DefaultChiefMachine {
  readonly workspace: string
  readonly team: string
  /** Stable logical machine id in the platform workspace. */
  readonly machine: string
  readonly provider: string
  /** Current `vm_<...>` carrier; this is what CloudDO.automationExec accepts. */
  readonly connection_machine: string
  readonly install: string
}

export interface DefaultHand {
  readonly hand: string
  readonly cwd: string
}

const B32 = "abcdefghijklmnopqrstuvwxyz234567"
const CWD = "/home/cmux/proj"

/** A deterministic hand id keeps outbox retries on the same HandDO. */
const defaultHandId = async (owner: string, chief: string, binding: DefaultChiefMachine): Promise<string> => {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
    `cmux-default-chief-hand\0${owner}\0${chief}\0${binding.team}\0${binding.machine}\0${binding.install}`,
  )))
  let bits = 0
  let nbits = 0
  let out = ""
  for (const byte of digest) {
    bits = (bits << 8) | byte
    nbits += 8
    while (nbits >= 5 && out.length < 20) {
      nbits -= 5
      out += B32[(bits >>> nbits) & 31]
    }
    if (out.length === 20) break
  }
  return `hand_${out}`
}

const base64 = (bytes: Uint8Array): string => {
  let raw = ""
  for (let i = 0; i < bytes.length; i += 0x8000) raw += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const base64Utf8 = (text: string): string => base64(new TextEncoder().encode(text))

const execFailure = (stage: string, result: { readonly ok: boolean; readonly exitCode?: number; readonly stderr?: string; readonly refusal?: string }): Error =>
  new Error(`default Chief hand ${stage} failed (${result.ok ? `exit ${result.exitCode ?? 1}` : result.refusal ?? "provider"})`)

/**
 * Installs and registers the persistent hand on the account's Cloud machine. The guest command
 * writes `hand.json` owner-only and returns only its key SHA; the bearer never appears in Worker
 * output or a provider response. Existing config is reused, so a retry after a Worker crash is
 * safe. The creator-only CloudDO method also prevents a Chief from provisioning another user's
 * machine.
 */
export const ensureDefaultHand = async (env: Env, owner: string, chief: string, binding: DefaultChiefMachine): Promise<DefaultHand> => {
  if (!binding.workspace || !binding.team || !/^vm_[A-Za-z0-9_-]{4,80}$/.test(binding.connection_machine) || !/^inst_[A-Za-z0-9_-]{1,80}$/.test(binding.install)) {
    throw new Error("default Chief machine binding is invalid")
  }
  const hand = await defaultHandId(owner, chief, binding)
  const api = env.CLOUD_API_ORIGIN ?? "https://cloud-api.cmux.dev"
  const key = base64(crypto.getRandomValues(new Uint8Array(32)))
  const config = JSON.stringify({ api, hand, key, profile: "sandbox", roots: [CWD], allow: [], agent_policy: "approve-edits" })
  const configB64 = base64Utf8(config)
  const script = [
    "set -eu",
    `home="${CWD.replace(/\/proj$/, "")}/.cmux-hand"; cfg="$home/hand.json"; tmp="$home/.default-hand.$$.json"`,
    "mkdir -p \"$home\"",
    `printf %s ${shellQuote(configB64)} | base64 -d >\"$tmp\"`,
    "if [ -f \"$cfg\" ]; then",
    `  existing_hand=$(sed -n 's/.*\"hand\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' \"$cfg\" | head -n 1)`,
    `  [ \"$existing_hand\" = ${shellQuote(hand)} ] || { rm -f \"$tmp\"; echo conflicting_default_hand >&2; exit 73; }`,
    `  existing_key=$(sed -n 's/.*\"key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' \"$cfg\" | head -n 1)`,
    `  [ -n \"$existing_key\" ] || { rm -f \"$tmp\"; echo missing_default_hand_key >&2; exit 73; }`,
    "  printf %s \"$existing_key\" | sha256sum | cut -d' ' -f1",
    "  rm -f \"$tmp\"",
    "else",
    "  chmod 600 \"$tmp\"; mv -f \"$tmp\" \"$cfg\"",
    `  printf %s ${shellQuote(key)} | sha256sum | cut -d' ' -f1`,
    "fi",
  ].join("\n")
  const cloud = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(binding.team)) as unknown as {
    automationExec(entity: string, user: string | null, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<{
      readonly ok: boolean
      readonly exitCode?: number
      readonly stdout?: string
      readonly stderr?: string
      readonly refusal?: string
    }>
  }
  const configured = await cloud.automationExec(binding.team, owner, binding.connection_machine, script, null, 15_000)
  if (!configured.ok || configured.exitCode !== 0) throw execFailure("config", configured)
  const guestSha = configured.stdout?.trim().split(/\s+/).at(-1) ?? ""
  if (!/^[0-9a-f]{64}$/.test(guestSha)) throw new Error("default Chief hand config did not return a key hash")
  const registered = await handStub(env, hand).ensureDefault(hand, owner, chief, guestSha)
  if (!registered.ok) throw new Error(`${registered.code}: ${registered.message}`)

  const install = `curl -fsSL ${shellQuote(`${api}/hand/install.sh`)} | sh -s -- --configured`
  const installed = await cloud.automationExec(binding.team, owner, binding.connection_machine, install, null, 75_000)
  if (!installed.ok || installed.exitCode !== 0) throw execFailure("install", installed)
  return { hand, cwd: CWD }
}

