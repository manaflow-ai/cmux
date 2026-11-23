import type { BuildSpace, Env, RawEnv } from "./env.ts"

/**
 * Build spaces: dev builds do not intertwine (AGENTS.md "Dev builds are separate").
 *
 * A dev build sends `X-Cmux-Build-Space: dev:<slug>` (its tag's slug, scripts/lib/mobile-attach.sh) on every
 * request and socket; nightly and stable send nothing and live in the base space "". Everything a build stores in a
 * per-build Durable Object is keyed by its space: `spacedEnv` prefixes `idFromName(name)` with `dev:<slug>|` for the
 * PER_BUILD bindings, so the ~260 `idFromName` call sites stay as they are and simply reach that space's objects.
 * ACCOUNT_WIDE bindings (membership, billing, machines) are one object for every build of the same person.
 *
 * Every Durable Object class takes the raw env in its constructor and re-derives its own space from its name
 * (`envForObject`), so its calls to other objects, its alarms, crons and outbox deliveries stay in its space.
 * Production never enters a dev space: it ignores the header (spaceOf), and an object named into a dev space there
 * refuses to start (envForObject).
 *
 * scripts/cmux-next/check-build-spaces.py (pre-push gate) refuses a Durable Object binding that is in neither list,
 * or in both, and raw env access to a per-build binding.
 */

export const BUILD_SPACE_HEADER = "x-cmux-build-space"
/** The base space: nightly, stable, and every request with no header. */
export const BASE_SPACE: BuildSpace = ""
/** `dev:` and the tag's slug: lowercase ASCII letters, digits and inner dashes, at most 64 characters. */
const DEV_SPACE = /^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/
/** Between a dev space and the object's own name in a per-build object's name. Never in a slug. */
const SEPARATOR = "|"

/**
 * Durable Object bindings whose objects are one per build space: what a build stores there is its own. Two are here
 * though they are keyed by something outside the person: ACCOUNT_INDEX_DO maps a provider account to the team
 * connections that linked it, and only ConnectionDO (per build) writes it, so a shared index would point nightly's
 * webhooks at a dev build's connections; ADDRESS_DO holds an invited address's delivery record and calls back into the
 * conversation that invited it, which is the inviting build's.
 */
export const PER_BUILD_BINDINGS = [
  "USER_DO",
  "CONVERSATION_DO",
  "FEED_DO",
  "MUX_DO",
  "CHIEF_BRAIN_DO",
  "CHIEF_DURABLE_DO",
  "OPENCODE_BRAIN_DO",
  "CONNECTION_DO",
  "ACCOUNT_INDEX_DO",
  "ADDRESS_DO",
  "HOST_DO",
  "HAND_DO",
  "PAIRING_DO",
  "SCHEDULER_DO",
  "HANDOFF_DO",
  "HANDOFF_INDEX_DO",
  "AUTO_SESSION_DO",
  "AUTO_SESSION_INDEX_DO",
  "TRAJECTORY_DO",
  "WIRE_TICKET_DO"
] as const

/**
 * Durable Object bindings shared by every build of the same person: team membership, SSO and plan (TEAM_DO, whose
 * host directory is still per build: each host records its space and a build lists only its own), email domains,
 * billing and spend (USAGE_METER_DO, SPEND_GUARD_DO, FREE_DEVICE_DO), cloud machines (TEAM_VM_DO, CLOUD_DO) and the one
 * live model catalog every build reads (MODEL_CATALOG_DO, which keeps nothing per user).
 */
export const ACCOUNT_WIDE_BINDINGS = ["TEAM_DO", "DOMAIN_DO", "USAGE_METER_DO", "SPEND_GUARD_DO", "FREE_DEVICE_DO", "TEAM_VM_DO", "CLOUD_DO", "MODEL_CATALOG_DO"] as const

export type PerBuildBinding = (typeof PER_BUILD_BINDINGS)[number]

/** A header value as a space, or null when it is not one. */
export const parseBuildSpace = (value: string | null | undefined): BuildSpace | null => {
  if (value === null || value === undefined || value === "") return BASE_SPACE
  return DEV_SPACE.test(value) ? (value as BuildSpace) : null
}

/** A dev space. A raw env (no BUILD_SPACE) reaches the raw bindings, which are the base space's. */
export const isDevSpace = (space: BuildSpace | undefined): boolean => typeof space === "string" && space.startsWith("dev:")

/** Production serves nightly and stable only: a dev space never exists there. */
/**
 * The environments that serve dev builds, an allow-list: production, and any environment whose name is missing or
 * misspelled, never builds a dev space. Previews deploy with ENVIRONMENT "development" (scripts/deploy-worker.sh).
 */
export const DEV_SPACE_ENVIRONMENTS: ReadonlySet<string> = new Set(["local", "test", "development", "staging"])
const devSpacesAllowed = (env: Pick<RawEnv, "ENVIRONMENT">) => DEV_SPACE_ENVIRONMENTS.has(env.ENVIRONMENT)

/**
 * The space of a request, from its header. Production ignores the header (base space, so a dev build pointed at
 * production behaves as the production build it talks to and never creates dev data there). Elsewhere a value that is
 * not a space is refused, never read as the base space: a dev build with a broken tag must not land in nightly's data.
 */
export const spaceOf = (request: Request, env: Pick<RawEnv, "ENVIRONMENT">): { ok: true; space: BuildSpace } | { ok: false; response: Response } => {
  if (!devSpacesAllowed(env)) return { ok: true, space: BASE_SPACE }
  const space = parseBuildSpace(request.headers.get(BUILD_SPACE_HEADER))
  if (space !== null) return { ok: true, space }
  return {
    ok: false,
    response: Response.json({ error: { code: "build_space.invalid", message: "X-Cmux-Build-Space must be dev:<slug> (lowercase letters, digits and dashes, at most 64)" } }, { status: 400 })
  }
}

/** The name a per-build object has in `space`; the base space keeps every name as it is. */
export const spacedName = (space: BuildSpace, name: string): string => (space === BASE_SPACE ? name : `${space}${SEPARATOR}${name}`)

/** The name inside `space` of a name spacedName gave. */
export const unspacedName = (space: BuildSpace, name: string): string => (space !== BASE_SPACE && name.startsWith(`${space}${SEPARATOR}`) ? name.slice(space.length + 1) : name)

/** The space a per-build object's name says, or the base space for an unprefixed name. */
export const spaceOfName = (name: string | undefined): BuildSpace => {
  if (!name?.startsWith("dev:")) return BASE_SPACE
  const at = name.indexOf(SEPARATOR)
  const space = at < 0 ? null : parseBuildSpace(name.slice(0, at))
  if (space === null || space === BASE_SPACE) throw new Error("build space: an object name starts with dev: but names no space")
  return space
}

/** The raw namespace behind a base-space one, so a shared object's env (envInSpace) can still name into a dev space. */
const rawNamespaces = new WeakMap<object, DurableObjectNamespace<Rpc.DurableObjectBranded | undefined>>()
const rawNamespace = <T extends Rpc.DurableObjectBranded | undefined>(ns: DurableObjectNamespace<T>): DurableObjectNamespace<T> =>
  (rawNamespaces.get(ns) as DurableObjectNamespace<T> | undefined) ?? ns

/** Whether a client-supplied name would land in a dev space's object (`dev:<slug>|…`, or any `dev:` name). */
export const namesDevSpace = (name: string): boolean => name.startsWith("dev:")

/**
 * A per-build namespace in the base space: every name as it is (nightly's objects byte for byte), except a name that
 * starts with `dev:`. Such a name is a dev space's object (spacedName), and a base-space caller passing a client's
 * text (an agent id, a conversation id) must never reach it.
 */
const baseNamespace = <T extends Rpc.DurableObjectBranded | undefined>(ns: DurableObjectNamespace<T>): DurableObjectNamespace<T> => {
  const checked = (name: string) => {
    if (namesDevSpace(name)) throw new Error("build space: a name in the base space starts with dev:, a dev space's object")
    return name
  }
  const base = {
    idFromName: (name: string) => ns.idFromName(checked(name)),
    idFromString: (id: string) => ns.idFromString(id),
    newUniqueId: (options?: DurableObjectNamespaceNewUniqueIdOptions) => ns.newUniqueId(options),
    get: (id: DurableObjectId, options?: DurableObjectNamespaceGetDurableObjectOptions) => ns.get(id, options),
    getByName: (name: string, options?: DurableObjectNamespaceGetDurableObjectOptions) => ns.get(ns.idFromName(checked(name)), options),
    jurisdiction: (jurisdiction: DurableObjectJurisdiction) => baseNamespace(ns.jurisdiction(jurisdiction))
  } as unknown as DurableObjectNamespace<T>
  rawNamespaces.set(base, ns as DurableObjectNamespace<Rpc.DurableObjectBranded | undefined>)
  return base
}

/** A namespace whose names live in `space`. Ids from strings and unique ids are refused in a dev space: their objects could not tell their space. */
const spacedNamespace = <T extends Rpc.DurableObjectBranded | undefined>(given: DurableObjectNamespace<T>, space: BuildSpace): DurableObjectNamespace<T> => {
  const ns = rawNamespace(given)
  const refuse = (what: string) => () => {
    throw new Error(`build space: ${what} is not available in a dev space`)
  }
  const spaced = {
    idFromName: (name: string) => ns.idFromName(spacedName(space, name)),
    get: (id: DurableObjectId, options?: DurableObjectNamespaceGetDurableObjectOptions) => ns.get(id, options),
    getByName: (name: string, options?: DurableObjectNamespaceGetDurableObjectOptions) => ns.get(ns.idFromName(spacedName(space, name)), options),
    idFromString: refuse("idFromString"),
    newUniqueId: refuse("newUniqueId"),
    jurisdiction: refuse("jurisdiction")
  }
  return spaced as unknown as DurableObjectNamespace<T>
}

/** A principal-shaped RPC argument (`identity` is the one field every principal has). */
const isPrincipal = (v: unknown): v is Record<string, unknown> & { identity: string } =>
  typeof v === "object" && v !== null && !Array.isArray(v) && typeof (v as { identity?: unknown }).identity === "string"

/**
 * A shared (account-wide) namespace reached from a dev space: every principal handed to one of its objects over RPC
 * carries that space as `build_space`, whoever built it. A shared object keeps its per-build parts apart by it
 * (TeamDO's host directory), so a principal a per-build object makes for itself (a chief's, a system one) is seen in
 * the space it acts in without each of them having to say so. The env decides, never the caller: a principal that
 * names another space is overwritten. HTTP fetches pass unchanged (the Worker sets their principal header).
 */
const principalsInSpace = <T extends Rpc.DurableObjectBranded | undefined>(ns: DurableObjectNamespace<T>, space: BuildSpace): DurableObjectNamespace<T> => {
  const wrap = (stub: DurableObjectStub<T>) =>
    new Proxy(stub as object, {
      get(target, prop) {
        const value = Reflect.get(target, prop) as unknown
        if (prop === "fetch" || prop === "connect" || typeof value !== "function") return value
        // Reflect.apply, not value.apply: an RPC stub answers every property, `apply` included, as a remote method.
        return (...args: Array<unknown>) => Reflect.apply(value as (...a: Array<unknown>) => unknown, target, args.map((a) => (isPrincipal(a) ? { ...a, build_space: space } : a)))
      }
    }) as DurableObjectStub<T>
  const shared = {
    idFromName: (name: string) => ns.idFromName(name),
    idFromString: (id: string) => ns.idFromString(id),
    newUniqueId: (options?: DurableObjectNamespaceNewUniqueIdOptions) => ns.newUniqueId(options),
    jurisdiction: (j: DurableObjectJurisdiction) => ns.jurisdiction(j),
    get: (id: DurableObjectId, options?: DurableObjectNamespaceGetDurableObjectOptions) => wrap(ns.get(id, options)),
    getByName: (name: string, options?: DurableObjectNamespaceGetDurableObjectOptions) => wrap(ns.get(ns.idFromName(name), options))
  }
  return shared as unknown as DurableObjectNamespace<T>
}

/**
 * The env of one build space: every PER_BUILD binding names its objects in `space`; everything else is the raw
 * binding. In the base space a PER_BUILD binding names every object as it is, so nightly and stable reach exactly the
 * objects they reached before build spaces existed, except a `dev:` name (a dev space's object): refused (baseNamespace).
 */
export const spacedEnv = (raw: RawEnv, space: BuildSpace): Env => {
  if (isDevSpace(space) && !devSpacesAllowed(raw)) throw new Error(`build space: environment "${raw.ENVIRONMENT}" serves no dev spaces (production and unknown environments are nightly and stable only)`)
  const out: Record<string, unknown> = { ...raw, BUILD_SPACE: space }
  if (isDevSpace(space)) {
    for (const binding of PER_BUILD_BINDINGS) {
      const ns = raw[binding] as DurableObjectNamespace | undefined
      if (ns) out[binding] = spacedNamespace(ns, space)
    }
    // CLOUD_DO is cmux-platform's: its principals are its own contract, and it keeps nothing per build.
    for (const binding of ACCOUNT_WIDE_BINDINGS.filter((b) => b !== "CLOUD_DO")) {
      const ns = raw[binding] as DurableObjectNamespace | undefined
      if (ns) out[binding] = principalsInSpace(ns, space)
    }
  } else {
    for (const binding of PER_BUILD_BINDINGS) {
      const ns = raw[binding] as DurableObjectNamespace | undefined
      if (ns) out[binding] = baseNamespace(ns)
    }
  }
  return out as unknown as Env
}

/** The key under which a per-build object remembers its space (for a wake that carries no name). */
const SPACE_KEY = "__build_space"

/**
 * The space of a Durable Object: its name's space, remembered in its storage the first time it is reached by name, so
 * an alarm or a wake without a name stays in the same space. An object that never had a name is in the base space.
 */
export const spaceOfObject = (ctx: DurableObjectState): BuildSpace => {
  const named = ctx.id.name
  const kv = ctx.storage.kv
  if (named !== undefined) {
    const space = spaceOfName(named)
    // Only a dev space is written: base objects stay byte for byte as they were.
    if (isDevSpace(space) && kv.get<string>(SPACE_KEY) !== space) kv.put(SPACE_KEY, space)
    return space
  }
  const stored = kv.get<string>(SPACE_KEY)
  const space = parseBuildSpace(stored)
  if (space === null) throw new Error("build space: an object holds a space that is not one")
  return space
}

/** The env every Durable Object class passes to its base class: the raw env seen from the object's own space. */
export const envForObject = (ctx: DurableObjectState, raw: RawEnv): Env => spacedEnv(raw, spaceOfObject(ctx))

/**
 * A shared object's way into one build space: TeamDO (one object for every build) pushes a dev build's host
 * revocation to the UserDO of that host's space. Only a base-space env may cross, and only into a space a record of
 * that object names (never a space a request asked for).
 */
export const envInSpace = (shared: Env, space: BuildSpace): Env => {
  if (shared.BUILD_SPACE !== BASE_SPACE) throw new Error("build space: only a shared object's env may reach another space")
  return space === BASE_SPACE ? shared : spacedEnv(shared as unknown as RawEnv, space)
}

/** The space an env reaches. */
export const spaceOfEnv = (env: { readonly BUILD_SPACE?: BuildSpace }): BuildSpace => (isDevSpace(env.BUILD_SPACE) ? env.BUILD_SPACE! : BASE_SPACE)
