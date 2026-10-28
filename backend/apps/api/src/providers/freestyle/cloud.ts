import type { Env } from "../../env.ts"
import { redactReason } from "../../cloud-redact.ts"
import { DriverError, type CloudProvider, type CloudProviderCapabilities, type CreateOptions, type EdgeTlsRule, type VmResources, type VmTag } from "../contract.ts"
import { createBody } from "./cloud-body.ts"
import { freestyleExecStdin } from "./exec.ts"
import type { CloudProviderWiring } from "../index.ts"

/** Freestyle sizes from the snapshot at create (resize is a separate, grow-only call); everything else it has. */
export const FREESTYLE_CLOUD_CAPABILITIES: CloudProviderCapabilities = { sizing: false, resize: true, snapshot: true, guestExec: true, edgeTls: true }

/** One page of a list (Freestyle's limit). */
const LIST_PAGE = 100

const REQUEST_TIMEOUT_MS = 20_000
const CREATE_TIMEOUT_MS = 120_000

/** Freestyle REST (the same v5 calls TeamVmDO's driver measured). Errors carry only the step, status and provider code. */
export class FreestyleCloudProvider implements CloudProvider {
  readonly capabilities = FREESTYLE_CLOUD_CAPABILITIES
  private readonly apiKey: string
  constructor(
    apiKey: string,
    private readonly baseUrl: string,
    private readonly snapshot: string,
    // A wrapper, never the bare global: workerd refuses fetch called as a method of another object (Illegal invocation).
    private readonly fetchFn: typeof fetch = (input, init) => fetch(input, init)
  ) {
    // A pasted key with a trailing newline would make every header invalid (review P2).
    this.apiKey = apiKey.trim()
  }

  private async call(method: string, path: string, body?: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<{ status: number; json: Record<string, unknown> }> {
    try {
      const res = await this.fetchFn(`${this.baseUrl.replace(/\/+$/, "")}${path}`, {
        method,
        headers: { authorization: `Bearer ${this.apiKey}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(timeoutMs)
      })
      return { status: res.status, json: (await res.json().catch(() => ({}))) as Record<string, unknown> }
    } catch (e) {
      // Network failure or timeout: the outcome is unknown; the retry finds the VM by name.
      // The reason (a runtime network message, never a header or key) goes into the error so a failure is diagnosable.
      const reason = redactReason(e instanceof Error ? `${e.name}: ${e.message}` : "unknown", this.apiKey)
      return { status: 0, json: { code: e instanceof Error && e.name === "TimeoutError" ? "TIMEOUT" : "UNREACHABLE", reason } }
    }
  }

  private fail(status: number, json: Record<string, unknown>, what: string): never {
    const final = status === 400 || status === 401 || status === 403 || status === 422
    const code = typeof json.code === "string" ? json.code.slice(0, 40) : ""
    const reason = status === 0 && typeof json.reason === "string" ? ` (${json.reason})` : ""
    throw new DriverError(final ? "cloud.provider.refused" : "cloud.provider.unavailable", `${what}: ${status || "no answer"}${code ? ` ${code}` : ""}${reason}`, final)
  }

  private vm(json: Record<string, unknown>) {
    if (typeof json.id !== "string" || json.id.length === 0) throw new DriverError("cloud.provider.refused", "answer without a VM id", true)
    return { id: json.id, tag: (json.metadata ?? {}) as Record<string, unknown> }
  }

  async find(name: string) {
    const got = await this.call("GET", `/v5/vms/${encodeURIComponent(name)}`)
    if (got.status === 404) return null
    if (got.status !== 200) this.fail(got.status, got.json, "read VM")
    return { ...this.vm(got.json), state: typeof got.json.state === "string" ? got.json.state : null }
  }

  async create(name: string, tag: VmTag, opts: CreateOptions) {
    const created = await this.call("POST", "/v5/vms", createBody(name, opts.snapshot ?? this.snapshot, tag, opts), CREATE_TIMEOUT_MS)
    if (created.status >= 200 && created.status < 300) return { id: this.vm(created.json).id, tag: null }
    // A duplicate name (409) or an unknown outcome: the VM under the name, if any, is the answer.
    const found = await this.find(name)
    if (found) return found
    this.fail(created.status, created.json, "create VM")
  }

  async writeFile(id: string, path: string, content: string, mode: number) {
    const bytes = new TextEncoder().encode(content)
    const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((b) => b.toString(16).padStart(2, "0")).join("")
    const q = new URLSearchParams({ path, mode: String(mode), sha256: digest })
    let status = 0
    try {
      const res = await this.fetchFn(`${this.baseUrl.replace(/\/+$/, "")}/v5/vms/${encodeURIComponent(id)}/fs/write?${q}`, {
        method: "PUT",
        headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/octet-stream" },
        body: bytes,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
      })
      status = res.status
      await res.body?.cancel()
    } catch {
      status = 0
    }
    // Never echo the body (it holds the bind token): only the step and status.
    if (status < 200 || status >= 300) this.fail(status, {}, "write bind file")
  }

  async list(filter: string, offset: number) {
    const q = new URLSearchParams({ metadata: filter, limit: String(LIST_PAGE), offset: String(offset) })
    const got = await this.call("GET", `/v5/vms?${q}`)
    if (got.status !== 200) this.fail(got.status, got.json, "list VMs")
    const vms = (Array.isArray(got.json.vms) ? got.json.vms : []) as Array<Record<string, unknown>>
    return {
      vms: vms.filter((v) => typeof v.id === "string").map((v) => ({ id: v.id as string, name: typeof v.slug === "string" ? v.slug : null, tag: (v.metadata ?? {}) as Record<string, unknown> })),
      total: typeof got.json.totalCount === "number" ? got.json.totalCount : vms.length
    }
  }

  async replaceTlsRule(vmId: string, rule: EdgeTlsRule) {
    const got = await this.call("GET", `/v5/tls?${new URLSearchParams({ vmId, domain: rule.domain })}`)
    if (got.status !== 200) this.fail(got.status, got.json, "list TLS rules")
    const id = ((Array.isArray(got.json.rules) ? got.json.rules : []) as Array<Record<string, unknown>>).find((r) => r.domain === rule.domain && typeof r.id === "string")?.id as string | undefined
    if (!id) return false
    // The answer may echo the request; only the step and status leave this method (the body holds the token).
    const r = await this.call("PUT", `/v5/tls/${encodeURIComponent(id)}`, rule)
    if (r.status >= 200 && r.status < 300) return true
    this.fail(r.status, {}, "replace TLS rule")
  }

  execStdin = (id: string, command: string, stdin: Uint8Array | null, timeoutMs: number) => freestyleExecStdin(this.fetchFn, this.baseUrl, this.apiKey, id, command, stdin, timeoutMs)
  async delete(id: string) {
    const r = await this.call("DELETE", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404 || (r.status >= 200 && r.status < 300)) return
    this.fail(r.status, r.json, "delete VM")
  }

  async pause(id: string) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/pause`)
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "pause VM")
  }

  async start(id: string) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/start`)
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "start VM")
  }

  async state(id: string) {
    const r = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404) return null
    if (r.status !== 200) this.fail(r.status, r.json, "read VM state")
    return typeof r.json.state === "string" ? r.json.state : null
  }

  async findSnapshot(slug: string) {
    const r = await this.call("GET", `/v5/snapshots/${encodeURIComponent(slug)}`)
    if (r.status === 404) return null
    if (r.status !== 200 || typeof r.json.id !== "string") this.fail(r.status, r.json, "read snapshot")
    return { id: r.json.id as string, sourceVmId: typeof r.json.sourceVmId === "string" ? r.json.sourceVmId : null }
  }

  async createSnapshot(vmId: string, slug: string) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(vmId)}/snapshot`, { slug }, CREATE_TIMEOUT_MS)
    if (r.status >= 200 && r.status < 300 && typeof r.json.snapshotId === "string") return { id: r.json.snapshotId }
    // A lost answer: the snapshot under the slug, if any, is the answer.
    const found = await this.findSnapshot(slug)
    if (found && found.sourceVmId === vmId) return { id: found.id }
    this.fail(r.status, r.json, "create snapshot")
  }

  async deleteSnapshot(id: string) {
    const r = await this.call("DELETE", `/v5/snapshots/${encodeURIComponent(id)}`)
    if (r.status === 404 || (r.status >= 200 && r.status < 300)) return
    this.fail(r.status, r.json, "delete snapshot")
  }

  async resize(id: string, size: VmResources) {
    const r = await this.call("POST", `/v5/vms/${encodeURIComponent(id)}/resize`, { cpu: size.cpu, memory: size.memory, storage: size.storage })
    if (r.status >= 200 && r.status < 300) return
    this.fail(r.status, r.json, "resize VM")
  }

  async resources(id: string) {
    const r = await this.call("GET", `/v5/vms/${encodeURIComponent(id)}`)
    if (r.status === 404) return null
    if (r.status !== 200) this.fail(r.status, r.json, "read VM resources")
    const res = (r.json.resources ?? {}) as Record<string, unknown>
    return typeof res.cpu === "number" && typeof res.memory === "number" && typeof res.storage === "number" ? { cpu: res.cpu, memory: res.memory, storage: res.storage } : null
  }
}

/**
 * The Freestyle wiring (providers/index.ts): its key and boot snapshot are CLOUD_FREESTYLE_* settings.
 * The account is shared with classic cmux Cloud, so GuardedCloudDriver's name and tag checks always wrap it.
 */
export const freestyleCloud: CloudProviderWiring = {
  id: "freestyle",
  keySet: (env: Env): boolean => Boolean(env.CLOUD_FREESTYLE_API_KEY),
  image: (env: Env): string | undefined => env.CLOUD_FREESTYLE_SNAPSHOT || undefined,
  make: (env: Env, image: string): CloudProvider => new FreestyleCloudProvider(env.CLOUD_FREESTYLE_API_KEY!, env.CLOUD_FREESTYLE_API_URL || "https://api.freestyle.sh", image)
}
