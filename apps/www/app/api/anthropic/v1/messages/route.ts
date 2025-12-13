import { createAnthropicProxyHandler } from "../../proxy-handler";

const ANTHROPIC_API_URL =
  "https://gateway.ai.cloudflare.com/v1/0c1675e0def6de1ab3a50a4e17dc5656/cmux-ai-proxy/anthropic/v1/messages";

export const POST = createAnthropicProxyHandler(
  ANTHROPIC_API_URL,
  "anthropic proxy"
);
