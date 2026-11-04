import { createFileRoute } from "@tanstack/react-router"
import { relayChat } from "../lib/ai-gateway-relay"

/** POST /api/ai-gateway/chat/completions: the Worker's Vercel AI Gateway OIDC relay (lib/ai-gateway-relay.ts). */
export const Route = createFileRoute("/api/ai-gateway/chat/completions")({
  server: {
    handlers: {
      POST: ({ request }) =>
        relayChat(request, {
          relayKey: process.env.INFERENCE_VERCEL_RELAY_KEY,
          // Vercel Functions pass the call's OIDC token in this header; the env copy covers older runtimes.
          oidcToken: request.headers.get("x-vercel-oidc-token") ?? process.env.VERCEL_OIDC_TOKEN,
          fetch
        })
    }
  }
})
