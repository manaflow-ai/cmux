import { expect, vi } from "vitest"
import { b64u, call, inDO, testEnv } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

export const NATIVE = "https://vm.test"
export const SERVICE_KEY = "test-network-target-service-key"
export const MESH = "mesh_00000000000000000000000000"
export const OTHER_MESH = "mesh_11111111111111111111111111"
export const mesh = (id = MESH) => ({ id, displayName: "Private mesh", ipv4Cidr: "10.128.0.0/20", createdAt: "2026-10-19T00:00:00Z" })

/** Real scoped app-token issuance; only the external Native service is replaced. */
export const targetFixture = async () => {
  const team = await rolesTeam()
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing app key")
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  const registered = await call("/v1/ops", team.creator.token, {
    op: "install.register", params: { public_jwk: jwk, kind: "mac", name: "Laptop", device_name: "Laptop", platform: "macos" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  })
  expect(registered.json.ok).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user: team.creator.user, install, team: team.team })
  expect(challenge.status).toBe(200)
  expect(challenge.json.message_prefix).toBe(`cmux-auth-team-v1\n${testEnv.ENVIRONMENT}\n${install}\n${team.team}\n`)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const issued = await call("/v1/auth/token", undefined, { user: team.creator.user, install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(issued.status).toBe(200)
  expect(issued.json.team).toBe(team.team)
  const token = issued.json.access_token as string, grant = issued.json.grant as string
  const owner = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team.team)) as any
  await inDO(owner, async (instance) => {
    instance.env = { ...instance.env, CLOUD_VM_API_ORIGIN: NATIVE, CLOUD_VM_API_SERVICE_KEY: SERVICE_KEY, CLOUD_VM_API_IMAGE: undefined, CLOUD_VM_API_IMAGE_REVISION: undefined }
  })
  const requests: Request[] = []
  let response = () => Response.json({ items: [mesh()] })
  let onRead: (() => Promise<void>) | undefined
  const fallback = globalThis.fetch
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init)
    if (!request.url.startsWith(`${NATIVE}/`)) return fallback(input, init)
    requests.push(request)
    expect(request.method).toBe("GET")
    expect(request.redirect).toBe("manual")
    expect(request.headers.get("authorization")).toBe(`Bearer ${SERVICE_KEY}`)
    expect(request.headers.get("x-cmux-team-id")).toBe(team.stackTeam)
    expect(request.headers.has("cookie")).toBe(false)
    expect(request.signal.aborted).toBe(false)
    const callback = onRead; onRead = undefined
    await callback?.()
    return response()
  })
  const read = (params: unknown = {}, credential = token, selectedTeam = team.team) => call("/v1/read", credential, { op: "host.network.target", params }, { "x-cmux-team": selectedTeam })
  const principal = { kind: "install" as const, identity: install, user: team.creator.user, team: team.team, install, grant, install_kind: "mac", grant_classes: ["read", "mutate-own"] }
  return { team, owner, token, install, grant, principal, read, requests,
    expected: { team: team.team, tenant: team.stackTeam, project: testEnv.STACK_PROJECT_ID, origin: NATIVE, mesh: MESH, ipv4_cidr: "10.128.0.0/20" },
    respond: (value: unknown, status = 200) => { response = () => Response.json(value, { status }) },
    rawResponse: (make: () => Response) => { response = make },
    onRead: (callback: () => Promise<void>) => { onRead = callback } }
}
