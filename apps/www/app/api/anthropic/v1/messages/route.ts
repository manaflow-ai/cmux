import { env } from "@/lib/utils/www-env";
import { verifyTaskRunToken } from "@/lib/utils/task-run-token";
import type { TaskRunTokenPayload } from "@/lib/utils/task-run-token";
import { NextRequest, NextResponse } from "next/server";

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages";

const allowedModels = new Set([
  "claude-3-5-haiku-20241022",
  "claude-sonnet-4-20250514",
  "claude-opus-4-1-20250805",
]);

const hardCodedApiKey = "sk_placeholder_cmux_anthropic_api_key";

async function requireTaskRunToken(
  request: NextRequest
): Promise<TaskRunTokenPayload> {
  const token = request.headers.get("x-cmux-token");
  if (!token) {
    throw new Error("Missing CMUX token");
  }

  return verifyTaskRunToken(token);
}

function getIsOAuthToken(token: string) {
  return token.includes("sk-ant-oat");
}

export async function POST(request: NextRequest) {
  let taskRunToken: TaskRunTokenPayload;
  try {
    taskRunToken = await requireTaskRunToken(request);
  } catch (authError) {
    console.error("[anthropic proxy] Auth error:", authError);
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  try {
    // Get query parameters
    const searchParams = request.nextUrl.searchParams;
    const beta = searchParams.get("beta");

    const xApiKeyHeader = request.headers.get("x-api-key");
    const authorizationHeader = request.headers.get("authorization");
    const isOAuthToken = getIsOAuthToken(
      xApiKeyHeader || authorizationHeader || ""
    );
    const useOriginalApiKey =
      !isOAuthToken &&
      xApiKeyHeader !== hardCodedApiKey &&
      authorizationHeader !== hardCodedApiKey;
    const body = await request.json();
    const model = body.model;
    if (!useOriginalApiKey && !allowedModels.has(model)) {
      return NextResponse.json(
        { error: "Model not allowed. Try /login instead." },
        { status: 400 }
      );
    }

    // Build headers
    const headers: Record<string, string> = useOriginalApiKey
      ? (() => {
          const filtered = new Headers(request.headers);
          filtered.delete("x-cmux-token");
          filtered.set("x-cmux-task-run-id", taskRunToken.taskRunId);
          return Object.fromEntries(filtered);
        })()
      : {
          "Content-Type": "application/json",
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
          "x-cmux-task-run-id": taskRunToken.taskRunId,
        };

    // Add beta header if beta param is present
    if (!useOriginalApiKey) {
      if (beta === "true") {
        headers["anthropic-beta"] = "messages-2023-12-15";
      }
    }

    const response = await fetch(ANTHROPIC_API_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });

    console.log(
      "[anthropic proxy] Anthropic response status:",
      response.status
    );

    // Handle streaming responses
    if (body.stream && response.ok) {
      // Create a TransformStream to pass through the SSE data
      const stream = new ReadableStream({
        async start(controller) {
          const reader = response.body?.getReader();
          if (!reader) {
            controller.close();
            return;
          }

          try {
            while (true) {
              const { done, value } = await reader.read();
              if (done) {
                controller.close();
                break;
              }
              controller.enqueue(value);
            }
          } catch (error) {
            console.error("[anthropic proxy] Stream error:", error);
            controller.error(error);
          }
        },
      });

      return new Response(stream, {
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        },
      });
    }

    // Handle non-streaming responses
    const data = await response.json();

    if (!response.ok) {
      console.error("[anthropic proxy] Anthropic error:", data);
      return NextResponse.json(data, { status: response.status });
    }

    return NextResponse.json(data);
  } catch (error) {
    console.error("[anthropic proxy] Error:", error);
    return NextResponse.json(
      { error: "Failed to proxy request to Anthropic" },
      { status: 500 }
    );
  }
}
