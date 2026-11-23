import { createFileRoute } from "@tanstack/react-router"
import { finishSignIn, signInConfig } from "../lib/sign-in-flow"

/** GET /auth/handoff?code=...&state=...: cmux.com sends the browser back here (lib/sign-in-flow.ts). */
export const Route = createFileRoute("/auth/handoff")({
  server: {
    handlers: {
      GET: ({ request }) =>
        finishSignIn(request, {
          config: signInConfig(request.headers.get("x-forwarded-host") ?? request.headers.get("host"), process.env),
          fetch,
          log: (reason) => console.warn("console.sign_in.refused", { reason })
        })
    }
  }
})
