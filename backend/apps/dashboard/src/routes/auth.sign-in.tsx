import { createFileRoute } from "@tanstack/react-router"
import { signInConfig, startSignIn } from "../lib/sign-in-flow"

/** GET /auth/sign-in?return_to=/path: starts Sign in with cmux (lib/sign-in-flow.ts). */
export const Route = createFileRoute("/auth/sign-in")({
  server: {
    handlers: {
      GET: ({ request }) => startSignIn(request, { config: signInConfig(request.headers.get("x-forwarded-host") ?? request.headers.get("host"), process.env) })
    }
  }
})
