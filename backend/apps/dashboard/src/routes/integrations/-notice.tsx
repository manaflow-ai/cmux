import { Link } from "@tanstack/react-router"
import type { IntegrationMessage } from "../../lib/integration-messages"

/**
 * One integration failure on the console: what happened, what to do next, and the button that does it (GitHub
 * integration audit fix 10). Never the bare error code.
 */
export function IntegrationNotice({ message, onConnect, onRetry }: { readonly message: IntegrationMessage; readonly onConnect?: () => void; readonly onRetry?: () => void }) {
  const action =
    message.button === "connect" && onConnect ? (
      <button onClick={onConnect}>Connect GitHub</button>
    ) : message.button === "retry" && onRetry ? (
      <button onClick={onRetry}>Try again</button>
    ) : message.button === "sign-in" ? (
      <Link to="/">Sign in</Link>
    ) : message.button === "connect" ? (
      <Link to="/integrations">Start again</Link>
    ) : null
  return (
    <div className={message.pending ? "muted" : "error"} role={message.pending ? "status" : "alert"}>
      <p>
        {message.text} {message.next}
      </p>
      {action ? <p>{action}</p> : null}
    </div>
  )
}
