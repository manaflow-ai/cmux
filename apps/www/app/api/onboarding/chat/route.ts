import { NextRequest } from "next/server";
import { getUserFromRequest } from "@/lib/utils/auth";
import { env } from "@/lib/utils/www-env";

const SYSTEM_PROMPT = `You are a friendly setup assistant helping a developer configure their preview environment.

Keep responses SHORT (1-2 sentences max). Be warm but concise. No markdown formatting.

Your job is to provide helpful context for each setup step when asked. The steps are:
1. Sync repository - explain why keeping the repo up to date matters
2. Install dependencies - clarify how to install packages or toolchains
3. Start dev server - explain which command should keep the preview running
4. Browser setup - ask for login/navigation steps the browser agent should follow
5. Additional notes - capture any other hints for previews or screenshots

Answer any questions briefly and helpfully.`;

// Use Convex Bedrock endpoint
function getAnthropicApiUrl(): string {
  const convexSiteUrl = env.NEXT_PUBLIC_CONVEX_URL.replace(
    ".convex.cloud",
    ".convex.site"
  );
  return `${convexSiteUrl}/api/anthropic/v1/messages`;
}

export async function POST(request: NextRequest) {
  const user = await getUserFromRequest(request);
  if (!user) {
    return new Response("Unauthorized", { status: 401 });
  }

  try {
    const body = await request.json();
    const { messages, step, repo } = body;

    const contextMessage = `Repository: ${repo || "unknown"}. Current step: ${step || "welcome"}.`;

    const response = await fetch(getAnthropicApiUrl(), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": "sk_placeholder_cmux_anthropic_api_key",
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-20250514",
        max_tokens: 150,
        system: `${SYSTEM_PROMPT}\n\n${contextMessage}`,
        messages,
        stream: true,
      }),
    });

    if (!response.ok) {
      const error = await response.text();
      console.error("[onboarding/chat] Bedrock error:", error);
      return new Response("Failed to get AI response", { status: 500 });
    }

    return new Response(response.body, {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      },
    });
  } catch (error) {
    console.error("[onboarding/chat] Error:", error);
    return new Response("Internal server error", { status: 500 });
  }
}
