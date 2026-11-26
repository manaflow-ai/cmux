import type { Env } from "../env.ts"

/**
 * The integrations hub for the Cloud Chief (RFD 0055 step 2, "Chief's hub_* tools"; Leo, 2026-11-23: "linking up
 * things like e.g. stripe so that your agents can refund for you etc."). `chief-hub search|describe|call|status` in a
 * turn machine (POST 127.0.0.1:4018/vm {action: hub_search|hub_describe|hub_call|hub_status}, chief-turn-runner
 * forwards it with the turn's token) reaches cmux-platform's hub over the PLATFORM binding
 * (POST /internal/v1/hub/chief/tools with INTERNAL_TOKEN), as the Chief `agent` of its `owner`, both taken from the
 * running turn's brain and never from the model's input. The hub keeps it agent-only: it searches, describes, calls
 * and reads status in the owner's own hub; linking, rules and approvals stay the person's. A call a rule holds comes
 * back `approval_required`; the person approves in Settings, Integrations, and `chief-hub status CALL` reads it.
 * GitHub, Slack and Google hub actions are not reachable this way (they run as the caller's bearer); Stripe is.
 */
type Out = { status: number; json: unknown }

export const HUB_ACTIONS = ["hub_search", "hub_describe", "hub_call", "hub_status"] as const
const MAX_ARGUMENTS_BYTES = 24 * 1024

/** One `chief-hub` call from the running turn of `agent`, a Chief of `owner`. */
export const hubCall = async (env: Pick<Env, "PLATFORM" | "INTERNAL_TOKEN">, owner: string | null | undefined, agent: string | null | undefined, raw: unknown): Promise<Out> => {
  const req = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as { action?: unknown; arguments?: unknown }
  if (typeof req.action !== "string" || !(HUB_ACTIONS as ReadonlyArray<string>).includes(req.action))
    return { status: 400, json: { error: `action must be one of ${HUB_ACTIONS.join(", ")}` } }
  const args = req.arguments === undefined ? {} : req.arguments
  if (!args || typeof args !== "object" || Array.isArray(args)) return { status: 400, json: { error: "arguments must be a JSON object" } }
  const body = JSON.stringify({ ownerUserId: owner, agent, name: req.action, arguments: args })
  if (body.length > MAX_ARGUMENTS_BYTES) return { status: 400, json: { error: `arguments must be at most ${MAX_ARGUMENTS_BYTES} bytes` } }
  if (!owner || !agent) return { status: 409, json: { error: "this Chief has no owner on record, so it has no integrations hub" } }
  if (!env.PLATFORM || !env.INTERNAL_TOKEN) return { status: 503, json: { error: "the integrations hub is not connected in this deployment" } }
  let response: Response
  try {
    response = await env.PLATFORM.fetch("https://platform/internal/v1/hub/chief/tools", {
      method: "POST",
      headers: { authorization: `Bearer ${env.INTERNAL_TOKEN}`, "content-type": "application/json" },
      body,
      signal: AbortSignal.timeout(30_000),
    })
  } catch (e) {
    return { status: 502, json: { error: `the integrations hub did not answer: ${e instanceof Error ? e.message : String(e)}` } }
  }
  const json = (await response.json().catch(() => null)) as { error?: { message?: unknown }; structuredContent?: unknown; content?: unknown; isError?: unknown } | null
  if (!response.ok) {
    const message = typeof json?.error?.message === "string" ? json.error.message : `HTTP ${response.status}`
    return { status: response.status === 404 ? 503 : 502, json: { error: response.status === 404 ? "the integrations hub is not enabled in this deployment" : `the integrations hub refused: ${message}` } }
  }
  // The tool result /mcp would give: structuredContent is the answer; isError marks a refusal the model should read.
  const result = json?.structuredContent ?? json?.content ?? null
  return { status: 200, json: json?.isError ? { error: result } : { result } }
}

/** `chief-hub`: the Chief's client (curl to chief-turn-runner on 127.0.0.1:4018). */
export const HUB_CLIENT = `#!/bin/sh
# chief-hub: your owner's integrations hub (apps/api/src/chief-brain-cc/hub.ts): the actions they linked
# (Stripe today) and the calls you made. You search, describe, call and read status; linking, rules and
# approvals are your owner's (Settings, Integrations). A call a rule holds answers approval_required:
# tell the person, then read it later with status.
#   chief-hub search [QUERY]                       linked and linkable actions
#   chief-hub describe ACTION                      one action's input schema and whether it is linked
#   chief-hub call ACTION ARGS_JSON [--connection C] [--invocation ID]
#                                                  call it (--invocation: a retry key; the same ID returns the same call)
#   chief-hub status CALL                          a call's state and result
set -eu
usage='usage: chief-hub search [QUERY] | describe ACTION | call ACTION ARGS_JSON [--connection C] [--invocation ID] | status CALL'
call() {
  # A request that could not be built (a missing file, bad JSON) arrives empty: send nothing, as the step above said.
  req=$(cat)
  [ -n "$req" ] || { echo "chief-hub: nothing was sent" >&2; exit 2; }
  out=$(printf '%s' "$req" | curl -sS -m 60 -w '\\n%{http_code}' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:4018/vm) || { echo "chief-hub: no turn is running on this machine (127.0.0.1:4018 does not answer)" >&2; exit 1; }
  code=$(printf '%s' "$out" | tail -n 1)
  body=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || { echo "chief-hub: $body" >&2; exit 1; }
  printf '%s' "$body" | node -e 'let s="";process.stdin.on("data",(d)=>s+=d).on("end",()=>{const j=JSON.parse(s);if(j.error!==undefined){process.stderr.write("chief-hub: "+JSON.stringify(j.error,null,2)+"\\n");process.exit(1)}process.stdout.write(JSON.stringify(j.result,null,2)+"\\n")})'
}
case "\${1:-}" in
  search)
    node -e 'process.stdout.write(JSON.stringify({action:"hub_search",arguments:process.argv[1]?{query:process.argv[1]}:{}}))' "\${2:-}" | call ;;
  describe)
    [ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
    node -e 'process.stdout.write(JSON.stringify({action:"hub_describe",arguments:{action:process.argv[1]}}))' "$2" | call ;;
  call)
    [ $# -ge 3 ] || { echo "$usage" >&2; exit 2; }
    shift
    # Built first, so a bad ARGS_JSON stops here (set -e) instead of sending an empty request down the pipe.
    payload=$(node -e '
      const [action, raw, ...rest] = process.argv.slice(1)
      let input
      try { input = JSON.parse(raw) } catch { process.stderr.write("chief-hub: ARGS_JSON is not JSON\\n"); process.exit(2) }
      const a = { action, args: input }
      for (let i = 0; i < rest.length; i += 2) {
        const k = rest[i], v = rest[i + 1]
        if (v === undefined || (k !== "--connection" && k !== "--invocation")) { process.stderr.write("chief-hub: unknown option " + k + "\\n"); process.exit(2) }
        a[k === "--connection" ? "connection" : "invocation_id"] = v
      }
      process.stdout.write(JSON.stringify({ action: "hub_call", arguments: a }))' "$@")
    printf '%s' "$payload" | call ;;
  status)
    [ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
    node -e 'process.stdout.write(JSON.stringify({action:"hub_status",arguments:{call:process.argv[1]}}))' "$2" | call ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
`
