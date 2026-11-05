import { cloudOpByName } from "@cmux/protocol"

/**
 * The strangler forwarder (manaflow-ai/cmux-platform docs/port-cloud-worker.md 3.1, row 1d): a
 * surface named in `PLATFORM_SURFACES` (comma separated, per environment) is served by the platform
 * Worker over the `PLATFORM` service binding; every other request runs the existing handler.
 *
 * Off by default. With `PLATFORM_SURFACES` unset or empty, `platformForward` returns at once without
 * reading the request, so the router behaves exactly as before. A listed surface with no `PLATFORM`
 * binding also stays local (and logs platform.forward.unbound), so a var set ahead of its binding never
 * breaks a route.
 *
 * Called after the entry ticket spend (spendTicketAtEntry), so a forwarded request carries an
 * already spent ticket and each ticket is spent exactly once, by cmux-api. The `wire` surface,
 * which the plan chooses by path before the spend, is not wired here yet.
 */

/** Surfaces this forwarder can hand to the platform. */
export type PlatformSurface = "cloud"

/** The surface of each op owner whose ops (on /v1/ops and /v1/read) can move. Owners not listed always stay. */
export const OWNER_SURFACE: Readonly<Partial<Record<string, PlatformSurface>>> = { "cloud:CloudDO": "cloud" }

const ACPMUX_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/acpmux\/(keyed-start|person-holds)$/
const TRAJECTORY_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/trajectories\/(append|native|list|read|native-read)$/
const CLIENT_SESSION_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/client-session$/
const GUEST_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/(exec|fs\/(?:dir|read|stat|write|mkdir|remove))$/
/** The machine routes only cmux-platform serves (cmux-api has no handler for them). */
const PLATFORM_ONLY_PATHS: ReadonlyArray<RegExp> = [/^\/v1\/cloud\/bind$/, /^\/v1\/cloud\/keyset$/, ACPMUX_PATH, CLIENT_SESSION_PATH, GUEST_PATH, TRAJECTORY_PATH]

/** NEXT Cloud's machine routes outside the op path (bind, keyset, keyed acpmux start, client session, guest exec and files, trajectories), the platform's Native network target read (cmux-platform NativeNetwork.ts) and the platform's remote off switch for the Mac's login copy (cmux-platform LoginCopySwitch.ts), which have no op and no route here. */
const CLOUD_PATHS: ReadonlyArray<RegExp> = [...PLATFORM_ONLY_PATHS, /^\/v1\/host\/network\/target$/, /^\/v1\/cloud\/harness-login-copy$/]

/** Whether a path is a NEXT Cloud machine route only cmux-platform serves. */
export const isCloudPath = (path: string): boolean => PLATFORM_ONLY_PATHS.some((p) => p.test(path))

/** The surfaces a `PLATFORM_SURFACES` value turns on; unknown names are ignored. */
export const platformSurfaces = (value: string | undefined): ReadonlySet<PlatformSurface> => {
  const on = new Set<PlatformSurface>()
  for (const name of (value ?? "").split(",")) if (name.trim() === "cloud") on.add("cloud")
  return on
}

/** The op endpoints, with the class of op each accepts (an op of the other class stays local and gets its validation.invalid). */
const OP_ENDPOINTS: Readonly<Record<string, "mutation" | "read">> = { "/v1/ops": "mutation", "/v1/read": "read" }

/** The surface a request belongs to, or undefined (stay local). Reads the body of a clone only for an op endpoint. */
const surfaceOf = async (request: Request, path: string, on: ReadonlySet<PlatformSurface>): Promise<PlatformSurface | undefined> => {
  if (on.has("cloud") && CLOUD_PATHS.some((p) => p.test(path))) return "cloud"
  const endpoint = OP_ENDPOINTS[path]
  if (!endpoint || request.method !== "POST" || !request.body) return undefined
  let op: unknown
  try {
    op = (JSON.parse(await request.clone().text()) as { op?: unknown } | null)?.op
  } catch {
    return undefined
  }
  if (typeof op !== "string") return undefined
  const def = cloudOpByName.get(op)
  if (!def || def.class !== endpoint) return undefined
  const surface = OWNER_SURFACE[def.owner]
  return surface && on.has(surface) ? surface : undefined
}

/** What the forwarder needs of the Worker's env; both are absent until the cutover deploy adds them. */
export interface PlatformForwardEnv {
  readonly PLATFORM?: Fetcher
  readonly PLATFORM_SURFACES?: string
}

/**
 * The platform's response when the request's surface is on and bound, else undefined (run the
 * existing handler). A platform that cannot be reached answers a retryable owner.unreachable: the
 * request is not replayed locally, since the platform may have acted on it.
 */
export const platformForward = async (request: Request, env: PlatformForwardEnv, path: string): Promise<Response | undefined> => {
  if (!env.PLATFORM_SURFACES) return undefined
  const on = platformSurfaces(env.PLATFORM_SURFACES)
  if (on.size === 0) return undefined
  const surface = await surfaceOf(request, path, on)
  if (!surface) return undefined
  if (!env.PLATFORM) {
    console.error(JSON.stringify({ msg: "platform.forward.unbound", surface, message: "PLATFORM_SURFACES names a surface but the PLATFORM binding is absent; serving locally" }))
    return undefined
  }
  try {
    return await env.PLATFORM.fetch(request)
  } catch (e) {
    console.error(JSON.stringify({ msg: "platform.forward.failed", surface, error: String(e).slice(0, 200) }))
    return Response.json({ error: { code: "owner.unreachable", message: "the platform could not be reached; retry", retryable: true } }, { status: 503 })
  }
}
