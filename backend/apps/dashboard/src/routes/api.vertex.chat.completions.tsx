import { createFileRoute } from "@tanstack/react-router"
import { relayVertexChat } from "../lib/vertex-relay"

/** POST /api/vertex/chat/completions: the Worker's keyless Vertex AI relay (lib/vertex-relay.ts). */
export const Route = createFileRoute("/api/vertex/chat/completions")({
  server: {
    handlers: {
      POST: ({ request }) =>
        relayVertexChat(request, {
          relayKey: process.env.INFERENCE_VERCEL_RELAY_KEY,
          // Vercel Functions pass the call's OIDC token in this header; the env copy covers older runtimes.
          oidcToken: request.headers.get("x-vercel-oidc-token") ?? process.env.VERCEL_OIDC_TOKEN,
          fetch
        })
    }
  }
})
