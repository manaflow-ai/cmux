import { createHash } from "node:crypto"
import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import type { MachineExecReply } from "./automation-machine.ts"
import { handStub, apiOrigin } from "./hand-api.ts"
import { layoutSelector, asDaemonUser, shellQuote } from "./cloud-acpmux-guest.ts"
import { personalTeamIdFor } from "./domains/user.ts"
import { platformCloud } from "./platform-cloud.ts"
import { declared } from "./do-stub.ts"

export interface DefaultChiefMachine {
  readonly workspace: string
  readonly team: string
  readonly machine: string
  readonly provider: string
  readonly connection_machine: string
  readonly install: string
}

export interface DefaultHandScope extends DefaultChiefMachine {
  readonly owner: string
  readonly chief: string
}

export interface DefaultHand {
  readonly hand: string
  readonly cwd: string
}

/** Exact scope, never a caller-selected machine or Chief. */
export const defaultHandScope = (scope: DefaultHandScope): string => JSON.stringify([
  scope.owner, scope.chief, scope.workspace, scope.team, scope.machine,
  scope.provider, scope.connection_machine, scope.install,
])

/** The 100-bit route id includes the install, so an obsolete carrier cannot replace its successor. */
export const defaultHandId = (scope: DefaultHandScope): string => {
  const bytes = createHash("sha256").update(`cmux-default-chief-hand\0${defaultHandScope(scope)}`).digest()
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567"
  let out = "", value = 0, bits = 0
  for (const byte of bytes) {
    value = (value << 8) | byte
    bits += 8
    while (bits >= 5 && out.length < 20) { bits -= 5; out += alphabet[(value >>> bits) & 31] }
    if (out.length === 20) break
  }
  return `hand_${out}`
}

type ReadReply = { ok: true; value: unknown; revision: string } | { ok: false; code: string; message: string }
interface ReadStub { readOp(entity: string, principal: Principal, op: string, params: unknown): Promise<ReadReply> }
export interface DefaultCloud extends ReadStub {
  automationExec(entity: string, owner: string, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply>
}
type Install = { id: string; kind: string; grant: string; revoked_at: unknown; bound_team?: string; bound_machine?: string }
type Grant = { id: string; grantee: string; revoked_at: unknown; expires_at: number | null; op_classes: ReadonlyArray<string> }

/** Fresh on every start/resume: both the user's grant and CloudDO's current VM carrier must agree. */
export const authorizeDefaultMachine = async (env: Env, scope: DefaultHandScope, options: { running?: boolean } = {}): Promise<DefaultCloud> => {
  const { owner, chief, team, workspace, install, connection_machine: carrier } = scope
  if (team !== personalTeamIdFor(owner) || workspace !== `chief-default-${owner}` || !/^vm_[a-z0-9]{20}$/.test(carrier)) throw new Error("chief.machine.invalid_scope")
  const user = declared(env.USER_DO.get(env.USER_DO.idFromName(owner)))
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner }
  const [record, installed] = await Promise.all([
    user.readOp(owner, principal, "chief.list", {}),
    user.readOp(owner, principal, "install.list", {}),
  ])
  if (!record.ok || !installed.ok) throw new Error("chief.machine.owner_unavailable")
  const c = (record.value as { chiefs: Array<{ id: string; owner_user: string; archived_at: string | null; brain_place?: unknown; cloud_machine?: DefaultChiefMachine }> }).chiefs.find((x) => x.id === chief)
  if (!c || c.owner_user !== owner || c.archived_at !== null || c.brain_place || !c.cloud_machine || defaultHandScope({ ...c.cloud_machine, owner, chief }) !== defaultHandScope(scope)) throw new Error("chief.machine.binding_changed")
  const state = installed.value as { installs: Array<Install>; grants: Array<Grant> }
  const i = state.installs.find((x) => x.id === install)
  const g = state.grants.find((x) => x.id === i?.grant)
  if (!i || i.kind !== "vm" || i.revoked_at !== null || i.bound_team !== team || i.bound_machine !== carrier
    || !g || g.grantee !== install || g.revoked_at !== null || !g.op_classes.includes("vm-self") || (g.expires_at !== null && (!Number.isFinite(g.expires_at) || g.expires_at <= Date.now()))) throw new Error("chief.machine.install_revoked")
  const cloud: DefaultCloud = platformCloud(env.CLOUD_DO, team)
  const self = await cloud.readOp(team, {
    identity: `install:${install}`, kind: "install", user: owner, team, install,
    grant: i.grant, install_kind: "vm", bound_machine: carrier, grant_classes: ["vm-self"],
  }, "cloud.vm.self.get", { machine: carrier })
  if (!self.ok) throw new Error(self.code === "owner.unreachable" ? "chief.machine.carrier_unavailable" : "chief.machine.carrier_changed")
  if ((self.value as { machine?: { status?: string; creator?: string } }).machine?.creator !== owner) throw new Error("chief.machine.carrier_changed")
  if (options.running !== false && (self.value as { machine?: { status?: string } }).machine?.status !== "running") throw new Error("chief.machine.not_running")
  return cloud
}

/** What the stored binding's checks answer when the platform moved its logical machine to another VM. */
const CARRIER_MOVED = new Set(["chief.machine.carrier_changed", "chief.machine.install_revoked"])
export type CarrierRebind = () => Promise<{ ok: true; changed: boolean; binding: DefaultChiefMachine } | { ok: false; code: string; retryable: boolean }>

/**
 * Authorizes the stored binding; when its VM or that VM's install no longer answers, follows the same logical
 * machine to the VM the platform names now (a shrink, a rewind, a fresh machine) and authorizes that one. A
 * refused or unchanged rebind keeps the original refusal, so a revoked install on the same VM stays revoked.
 */
export const followDefaultCarrier = async (
  binding: DefaultChiefMachine,
  authorize: (binding: DefaultChiefMachine) => Promise<unknown>,
  rebind: CarrierRebind
): Promise<DefaultChiefMachine> => {
  try {
    await authorize(binding)
    return binding
  } catch (error) {
    if (!(error instanceof Error) || !CARRIER_MOVED.has(error.message)) throw error
    const moved = await rebind().catch(() => null)
    if (!moved?.ok || !moved.changed) throw error
    await authorize(moved.binding)
    return moved.binding
  }
}

/** ``authorizeDefaultMachine`` that follows its logical machine to a new VM (``followDefaultCarrier``). */
export const authorizeDefaultMachineFollowing = (env: Env, owner: string, chief: string, binding: DefaultChiefMachine, options: { running?: boolean } = {}): Promise<DefaultChiefMachine> =>
  followDefaultCarrier(binding, (b) => authorizeDefaultMachine(env, { ...b, owner, chief }, options),
    () => declared(env.USER_DO.get(env.USER_DO.idFromName(owner))).rebindDefaultChief(owner, chief))

/** No bearer is in this script, stdin, a provider argument, or its result. Only the guest creates it. */
export const DEFAULT_HAND_GUEST_CONFIG = `import fcntl, hashlib, json, os, re, secrets, stat, sys, tempfile
expected = json.load(sys.stdin)
home = os.path.expanduser("~")
directory = os.path.join(home, ".cmux-chief-hand")
cwd = os.path.join(home, "proj")
os.makedirs(directory, mode=0o700, exist_ok=True)
if not stat.S_ISDIR(os.lstat(directory).st_mode): raise RuntimeError("hand directory conflict")
os.chmod(directory, 0o700)
def moved(was, now):
    try: was, now = json.loads(was), json.loads(now)
    except Exception: return False
    return isinstance(was, list) and isinstance(now, list) and len(was) == len(now) == 8 and was[:6] == now[:6] and was[6:] != now[6:]
def fresh(policy):
    return {"api": expected["api"], "hand": expected["hand"], "default_scope": expected["scope"], "key": secrets.token_urlsafe(32), "profile": "sandbox", "roots": [cwd], "allow": [], "agent_policy": policy}
def write(config, place):
    fd, tmp = tempfile.mkstemp(prefix=".hand-", dir=directory)
    try:
        with os.fdopen(fd, "w") as staged:
            json.dump(config, staged)
            staged.flush()
            os.fsync(staged.fileno())
        place(tmp, path)
    finally:
        if os.path.lexists(tmp): os.unlink(tmp)
lock = os.open(os.path.join(directory, ".provision.lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
with os.fdopen(lock, "w") as held:
    fcntl.flock(held, fcntl.LOCK_EX)
    path = os.path.join(directory, "hand.json")
    if os.path.lexists(path):
        if not stat.S_ISREG(os.lstat(path).st_mode): raise RuntimeError("hand config conflict")
        with open(path) as current: config = json.load(current)
        if config.get("agent_policy") not in ["ask", "approve-reads", "approve-edits", "deny-all"]: raise RuntimeError("hand policy conflict")
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", config.get("key", "")): raise RuntimeError("hand key conflict")
        if any(config.get(k) != v for k, v in {"api": expected["api"], "hand": expected["hand"], "default_scope": expected["scope"], "profile": "sandbox", "roots": [cwd]}.items()):
            # A home copied from this logical machine's earlier VM (a shrink, a rewind): the same owner, Chief,
            # workspace, team, machine and provider, another VM and install. It gets a new identity and key.
            if not moved(config.get("default_scope"), expected["scope"]) or config.get("api") != expected["api"] or config.get("profile") != "sandbox" or config.get("roots") != [cwd]: raise RuntimeError("hand identity conflict")
            config = fresh(config["agent_policy"])
            write(config, os.replace)
        os.chmod(path, 0o600)
    else:
        config = fresh("approve-edits")
        write(config, os.link)
    os.makedirs(cwd, exist_ok=True)
    print(json.dumps({"key_sha": hashlib.sha256(config["key"].encode()).hexdigest(), "cwd": cwd}))
`

const failed = (stage: string, result: MachineExecReply): Error => new Error(`chief.hand.${stage}:${result.ok ? `exit_${result.exitCode}` : result.refusal}`)

/** Retry-safe guest-first registration. The bearer remains on the VM for its entire lifetime. */
export const ensureDefaultHand = async (env: Env, owner: string, chief: string, binding: DefaultChiefMachine): Promise<DefaultHand> => {
  if (env.CHIEF_BRAIN_ENABLED !== "1" || env.HANDS_ENABLED !== "1") throw new Error("chief.hand.disabled")
  const scope = { ...binding, owner, chief }
  const hand = defaultHandId(scope)
  const api = apiOrigin(env)
  const origin = new URL(api)
  if (origin.protocol !== "https:" || origin.origin !== api) throw new Error("chief.hand.invalid_origin")
  const cloud = await authorizeDefaultMachine(env, scope)
  const command = `${layoutSelector()} && ${asDaemonUser(`python3 -c ${shellQuote(DEFAULT_HAND_GUEST_CONFIG)}`)}`
  const config = await cloud.automationExec(binding.team, owner, binding.connection_machine, command, new TextEncoder().encode(JSON.stringify({ api, hand, scope: defaultHandScope(scope) })), 15_000)
  if (!config.ok || config.exitCode !== 0) throw failed("config", config)
  let guest: { key_sha?: string; cwd?: string } | undefined
  try { guest = JSON.parse(config.stdout) as typeof guest } catch { /* No guest logs or secrets in errors. */ }
  if (!guest?.key_sha || !/^[0-9a-f]{64}$/.test(guest.key_sha) || !["/home/cmux/proj", "/root/proj"].includes(guest.cwd ?? "")) throw new Error("chief.hand.invalid_config_reply")
  await authorizeDefaultMachine(env, scope)
  const registered = await handStub(env, hand).ensureDefault(scope, guest.key_sha)
  if (!registered.ok) throw new Error(registered.code)
  if (await handStub(env, hand).waitOnline(1)) return { hand, cwd: guest.cwd! }
  // Installing as the daemon's user is what makes the hand see the user's provider login.
  const install = `${layoutSelector()} && ${asDaemonUser(`sh -c ${shellQuote(`export CMUX_HAND_HOME="$HOME/.cmux-chief-hand"; curl -fsSL ${shellQuote(`${api}/hand/install.sh`)} | sh -s -- --configured --binary "$HOME/.cmux/bin/cmux-tui" --multicall`)}`)}`
  const installed = await cloud.automationExec(binding.team, owner, binding.connection_machine, install, null, 75_000)
  if (!installed.ok || installed.exitCode !== 0) throw failed("install", installed)
  if (!(await handStub(env, hand).waitOnline(30_000))) throw new Error("chief.hand.offline")
  return { hand, cwd: guest.cwd! }
}
