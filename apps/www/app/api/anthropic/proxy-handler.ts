import { verifyTaskRunToken, type TaskRunTokenPayload } from "@cmux/shared";
import { env } from "@/lib/utils/www-env";
import { NextRequest, NextResponse } from "next/server";

const TEMPORARY_DISABLE_AUTH = true;
const hardCodedApiKey = "sk_placeholder_cmux_anthropic_api_key";

async function requireTaskRunToken(
  request: NextRequest
): Promise<TaskRunTokenPayload> {
  const token = request.headers.get("x-cmux-token");
  if (!token) {
    throw new Error("Missing CMUX token");
  }

  return verifyTaskRunToken(token, env.CMUX_TASK_RUN_JWT_SECRET);
}

function getIsOAuthToken(token: string) {
  return token.includes("sk-ant-oat");
}

export function createAnthropicProxyHandler(apiUrl: string, logPrefix: string) {
  return async function POST(request: NextRequest) {
    if (!TEMPORARY_DISABLE_AUTH) {
      try {
        await requireTaskRunToken(request);
      } catch (authError) {
        console.error(`[${logPrefix}] Auth error:`, authError);
        return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
      }
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

      // Build headers
      const headers: Record<string, string> =
        useOriginalApiKey && !TEMPORARY_DISABLE_AUTH
          ? (() => {
              const filtered = new Headers(request.headers);
              return Object.fromEntries(filtered);
            })()
          : {
              "Content-Type": "application/json",
              "x-api-key": env.ANTHROPIC_API_KEY,
              "anthropic-version": "2023-06-01",
            };

      // Add beta header if beta param is present
      if (!useOriginalApiKey) {
        if (beta === "true") {
          headers["anthropic-beta"] = "messages-2023-12-15";
        }
      }

      const response = await fetch(apiUrl, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      });

      console.log(`[${logPrefix}] Anthropic response status:`, response.status);

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
              console.error(`[${logPrefix}] Stream error:`, error);
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
        console.error(`[${logPrefix}] Anthropic error:`, data);
        return NextResponse.json(data, { status: response.status });
      }

      return NextResponse.json(data);
    } catch (error) {
      console.error(`[${logPrefix}] Error:`, error);
      return NextResponse.json(
        { error: "Failed to proxy request to Anthropic" },
        { status: 500 }
      );
    }
  };
}
