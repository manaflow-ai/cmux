/**
 * What the console says when an integration step fails (GitHub integration audit fix 10): one table keyed by the API's
 * error code, each with a sentence for the person and the step that fixes it. The page never prints `code: message`.
 * The API's own `error.next` (api src/integrations/github-next.ts) wins over the table's step when it gave one; the
 * table is what the console says for a code the API answered without one (another provider, an older API).
 */
export interface IntegrationMessage {
  /** What happened, in one sentence. */
  readonly text: string
  /** What to do next, in one sentence; empty when nothing needs doing. */
  readonly next: string
  /** The button that does `next` on this page, when one does. */
  readonly button?: "connect" | "retry" | "sign-in"
  /** Not a failure (a request waiting on someone): shown without the error color. */
  readonly pending?: true
}

const MESSAGES: Readonly<Record<string, IntegrationMessage>> = {
  "integration.not_found": { text: "GitHub isn't connected for this team.", next: "Connect GitHub, then try again.", button: "connect" },
  "github.not_connected": { text: "GitHub isn't connected for this team.", next: "Connect GitHub, then try again.", button: "connect" },
  needs_reauth: { text: "The team's GitHub connection needs linking again.", next: "Connect GitHub again.", button: "connect" },
  "integration.state_invalid": { text: "This connection link expired or belongs to another sign-in.", next: "Start the connection again.", button: "connect" },
  "integration.not_configured": { text: "This integration isn't set up on this deployment.", next: "Ask the person who runs this cmux server to configure it." },
  "integration.unavailable": { text: "cmux couldn't reach the provider just now.", next: "Try again in a minute.", button: "retry" },
  "policy.denied": { text: "The team's policy doesn't allow this.", next: "Ask a team admin to change the team's policy below." },
  "auth.required": { text: "Your sign-in ended.", next: "Sign in again.", button: "sign-in" },
  "auth.forbidden": { text: "Your role in this team can't do this.", next: "Ask a team admin." },
  rate_limited: { text: "The provider asked cmux to slow down.", next: "Wait a minute, then try again.", button: "retry" },
  "provider.error": { text: "The provider refused the request.", next: "Try again; if it keeps failing, disconnect and connect again.", button: "retry" },
  "validation.invalid": { text: "The request wasn't accepted.", next: "Check the values and try again." },
}

/** An organization member's GitHub install sent to the organization's owners (`setup_action=request`). */
export const OWNER_REQUEST_MESSAGE: IntegrationMessage = {
  text: "GitHub sent your request to install the cmux GitHub App to your organization's owners.",
  next: "When an owner approves it, connect GitHub again.",
  button: "connect",
  pending: true,
}

/** The provider's page was closed or cancelled (`error=access_denied` and the like). */
export const CANCELLED_MESSAGE: IntegrationMessage = { text: "The connection was cancelled on the provider's page.", next: "Start it again when you're ready.", button: "connect" }

/** The words for a failed API answer: the table's entry for its code, with the API's own `next` when it sent one. */
export const integrationMessage = (error: { readonly code?: unknown; readonly message?: unknown; readonly next?: unknown } | null | undefined, status?: number): IntegrationMessage => {
  const code = typeof error?.code === "string" ? error.code : status === 401 ? "auth.required" : ""
  const known = MESSAGES[code]
  const next = typeof error?.next === "string" && error.next.trim() ? error.next.trim() : undefined
  if (known) return next ? { ...known, next } : known
  // An unknown code: the API's message is written for people; never the bare code.
  const text = typeof error?.message === "string" && error.message.trim() ? sentence(error.message.trim()) : "Something went wrong."
  return { text, next: next ?? "Try again.", button: "retry" }
}

/** One line for a page that has room for one: the sentence and its step. */
export const integrationMessageLine = (m: IntegrationMessage): string => (m.next ? `${m.text} ${m.next}` : m.text)

const sentence = (s: string): string => {
  const first = s.charAt(0).toUpperCase() + s.slice(1)
  return /[.!?]$/.test(first) ? first : `${first}.`
}
