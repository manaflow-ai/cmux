/**
 * Small, credential-free operation bridge used by cmux NEXT and acpmux hosts.
 *
 * The bridge deliberately knows only operation shapes and service endpoints. A
 * caller supplies a short-lived credential and an idempotency key; no token is
 * persisted or included in returned values. In production `http` is the Worker
 * fetch, while tests and a local acpmux host inject a fake transport.
 */

export type StrategyProvider = "github" | "linear" | "slack" | "preview" | "cloud"
export type StrategyAction =
  | "github.comment"
  | "linear.issue.create"
  | "slack.message.post"
  | "preview.create"
  | "cloud.machine.create"
  | "cloud.machine.attach"
  | "cloud.machine.release"

export interface StrategyRequest {
  provider: StrategyProvider
  action: StrategyAction
  mutation_id: string
  input: Record<string, unknown>
}

export interface StrategyResult {
  provider: StrategyProvider
  action: StrategyAction
  id: string
  url?: string
  status?: string
  metadata?: Record<string, unknown>
}

export interface StrategyBridgeConfig {
  github_api?: string
  linear_api?: string
  slack_api?: string
  preview_api?: string
  cloud_api?: string
}

export interface StrategyHttp {
  request(request: Request): Promise<Response>
}

const defaults: Required<StrategyBridgeConfig> = {
  github_api: "https://api.github.com",
  linear_api: "https://api.linear.app",
  slack_api: "https://slack.com/api",
  preview_api: "https://api.vercel.com",
  cloud_api: "https://cloud.cmux.dev"
}

const actions: Readonly<Record<StrategyAction, StrategyProvider>> = {
  "github.comment": "github",
  "linear.issue.create": "linear",
  "slack.message.post": "slack",
  "preview.create": "preview",
  "cloud.machine.create": "cloud",
  "cloud.machine.attach": "cloud",
  "cloud.machine.release": "cloud"
}

const text = (input: Record<string, unknown>, key: string, max = 512): string => {
  const value = input[key]
  if (typeof value !== "string" || value.trim().length === 0 || value.length > max) throw new Error(`input.${key} must be a non-empty string of at most ${max} characters`)
  return value
}

const optionalText = (input: Record<string, unknown>, key: string, max = 512): string | undefined => {
  const value = input[key]
  if (value === undefined) return undefined
  return text(input, key, max)
}

const baseUrl = (raw: string): URL => {
  const parsed = new URL(raw)
  // Production endpoints must be HTTPS. Loopback HTTP is useful for a local
  // acpmux adapter and is intentionally the only insecure exception.
  if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && (parsed.hostname === "127.0.0.1" || parsed.hostname === "localhost"))) {
    throw new Error("integration endpoint must use HTTPS (or loopback HTTP for local development)")
  }
  return parsed
}

const endpoint = (raw: string, path: string): string => {
  const root = baseUrl(raw)
  root.pathname = `${root.pathname.replace(/\/$/, "")}/${path.replace(/^\//, "")}`
  root.search = ""
  return root.toString()
}

const json = async (response: Response): Promise<Record<string, unknown>> => {
  const body = await response.json().catch(() => ({}))
  return body && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : {}
}

const result = (provider: StrategyProvider, action: StrategyAction, body: Record<string, unknown>): StrategyResult => {
  const id = typeof body.id === "string" ? body.id : typeof body.deploymentId === "string" ? body.deploymentId : typeof body.machine_id === "string" ? body.machine_id : ""
  if (!id) throw new Error(`${provider} response did not include an id`)
  return {
    provider,
    action,
    id,
    ...(typeof body.url === "string" ? { url: body.url } : typeof body.preview_url === "string" ? { url: body.preview_url } : {}),
    ...(typeof body.status === "string" ? { status: body.status } : typeof body.state === "string" ? { status: body.state } : {}),
    metadata: body
  }
}

export class StrategyIntegrationBridge {
  private readonly config: Required<StrategyBridgeConfig>
  private readonly http: StrategyHttp

  constructor(config: StrategyBridgeConfig = {}, http: StrategyHttp = { request: (request) => fetch(request) }) {
    this.config = { ...defaults, ...config }
    for (const value of Object.values(this.config)) baseUrl(value)
    this.http = http
  }

  async run(request: StrategyRequest, credential: string): Promise<StrategyResult> {
    if (!Object.hasOwn(actions, request.action) || actions[request.action] !== request.provider) throw new Error("provider/action mismatch")
    if (!/^[-A-Za-z0-9_.:]{8,128}$/.test(request.mutation_id)) throw new Error("mutation_id must be 8..128 safe characters")
    if (typeof credential !== "string" || credential.length < 8) throw new Error("a short-lived integration credential is required")
    const headers = { authorization: `Bearer ${credential}`, "content-type": "application/json", "idempotency-key": request.mutation_id }
    let url: string
    let body: Record<string, unknown>
    switch (request.action) {
      case "github.comment":
        url = endpoint(this.config.github_api, `repos/${text(request.input, "repo")}/issues/${text(request.input, "issue", 32)}/comments`)
        body = { body: text(request.input, "body", 20_000) }
        break
      case "linear.issue.create":
        url = endpoint(this.config.linear_api, "graphql")
        body = {
          query: "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }",
          variables: { input: { teamId: text(request.input, "team_id"), title: text(request.input, "title", 512), ...(optionalText(request.input, "description", 20_000) ? { description: optionalText(request.input, "description", 20_000) } : {}) } }
        }
        break
      case "slack.message.post":
        url = endpoint(this.config.slack_api, "chat.postMessage")
        body = { channel: text(request.input, "channel", 128), text: text(request.input, "text", 40_000) }
        break
      case "preview.create":
        url = endpoint(this.config.preview_api, "v13/deployments")
        body = {
          name: text(request.input, "project", 128),
          gitSource: { type: "github", ref: text(request.input, "git_ref", 256), ...(optionalText(request.input, "commit", 128) ? { sha: optionalText(request.input, "commit", 128) } : {}) },
          target: "preview",
          ...(optionalText(request.input, "team_id", 128) ? { teamId: optionalText(request.input, "team_id", 128) } : {})
        }
        break
      case "cloud.machine.create":
        url = endpoint(this.config.cloud_api, "v1/machines")
        body = { vendor: text(request.input, "vendor", 32), region: text(request.input, "region", 64), sku: text(request.input, "sku", 128), ttl_seconds: boundedNumber(request.input, "ttl_seconds", 60, 2_592_000), labels: labels(request.input.labels) }
        break
      case "cloud.machine.attach":
        url = endpoint(this.config.cloud_api, `v1/machines/${text(request.input, "machine_id", 128)}/attach`)
        body = { session_id: text(request.input, "session_id", 256), client: "cmux-next" }
        break
      case "cloud.machine.release":
        url = endpoint(this.config.cloud_api, `v1/machines/${text(request.input, "machine_id", 128)}/release`)
        body = {}
        break
    }
    const response = await this.http.request(new Request(url, { method: "POST", headers, body: JSON.stringify(body) }))
    const payload = await json(response)
    if (!response.ok) throw new Error(`${request.provider} ${request.action} failed with HTTP ${response.status}`)
    if (request.action === "linear.issue.create") {
      const issue = (payload.data as Record<string, unknown> | undefined)?.issueCreate as Record<string, unknown> | undefined
      if (!issue || issue.success !== true) throw new Error("linear issue creation was not successful")
      return result(request.provider, request.action, issue.issue as Record<string, unknown>)
    }
    if (request.action === "slack.message.post" && payload.ok !== true) throw new Error("slack message was not accepted")
    return result(request.provider, request.action, payload)
  }
}

const boundedNumber = (input: Record<string, unknown>, key: string, min: number, max: number): number => {
  const value = input[key]
  if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) throw new Error(`input.${key} must be an integer from ${min} to ${max}`)
  return value
}

const labels = (input: unknown): Record<string, string> => {
  if (input === undefined) return {}
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("input.labels must be an object")
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(input)) {
    if (!/^[a-z0-9_.-]{1,63}$/.test(key) || typeof value !== "string" || value.length > 63) throw new Error("input.labels contains an invalid key or value")
    out[key] = value
  }
  return out
}
