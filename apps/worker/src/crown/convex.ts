import { log } from "../logger";

export function getConvexBaseUrl(override?: string): string | null {
  const url = override ?? process.env.NEXT_PUBLIC_CONVEX_URL;
  if (!url) {
    log(
      "ERROR",
      "NEXT_PUBLIC_CONVEX_URL is not configured; cannot call crown endpoints"
    );
    return null;
  }
  const httpActionUrl = url.replace(".convex.cloud", ".convex.site");
  return httpActionUrl.replace(/\/$/, "");
}

export async function debugCrownWorkflow(
  stage: string,
  context: Record<string, unknown>,
  token?: string,
  baseUrlOverride?: string
): Promise<void> {
  const baseUrl = getConvexBaseUrl(baseUrlOverride);
  if (!baseUrl || !token) {
    return;
  }

  try {
    await fetch(`${baseUrl}/api/crown/debug`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-cmux-token": token,
      },
      body: JSON.stringify({
        stage,
        ...context,
        timestamp: new Date().toISOString(),
      }),
    });
  } catch {
    // Silently fail debug calls
  }
}

export async function convexRequest<T>(
  path: string,
  token: string,
  body: Record<string, unknown>,
  baseUrlOverride?: string
): Promise<T | null> {
  const baseUrl = getConvexBaseUrl(baseUrlOverride);
  if (!baseUrl) {
    return null;
  }

  const fullUrl = `${baseUrl}${path}`;
  log("DEBUG", "Making Crown HTTP request", { url: fullUrl, path });

  try {
    const response = await fetch(fullUrl, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-cmux-token": token,
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const errorText = await response.text().catch(() => "<no body>");
      log("ERROR", `Crown request failed (${response.status})`, {
        url: fullUrl,
        path,
        body,
        errorText,
      });
      return null;
    }

    return (await response.json()) as T;
  } catch (error) {
    log("ERROR", "Failed to reach crown endpoint", {
      url: fullUrl,
      path,
      error,
    });
    return null;
  }
}
