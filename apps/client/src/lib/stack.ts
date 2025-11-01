import { client as wwwOpenAPIClient } from "@cmux/www-openapi-client/client.gen";
import { StackClientApp } from "@stackframe/react";
import { useNavigate as useTanstackNavigate } from "@tanstack/react-router";
import { env } from "../client-env";
import { AUTH_JSON_QUERY_KEY } from "../contexts/convex/authJsonQueryOptions";
import { signalConvexAuthReady } from "../contexts/convex/convex-auth-ready";
import { convexQueryClient } from "../contexts/convex/convex-query-client";
import { queryClient } from "../query-client";
import { cachedGetUser, resetCachedUserCache } from "./cachedGetUser";
import { WWW_ORIGIN } from "./wwwOrigin";

export const stackClientApp = new StackClientApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
  tokenStore: "cookie",
  redirectMethod: {
    useNavigate() {
      const navigate = useTanstackNavigate();
      return (to: string) => {
        navigate({ to });
      };
    },
  },
});

convexQueryClient.convexClient.setAuth(
  stackClientApp.getConvexClientAuth({ tokenStore: "cookie" }),
  (isAuthenticated) => {
    signalConvexAuthReady(isAuthenticated);
  },
);

const MAX_AUTH_RETRIES = 1;

function applyHeaders(target: Headers, source?: HeadersInit) {
  if (!source) {
    return;
  }
  new Headers(source).forEach((value, key) => {
    target.set(key, value);
  });
}

async function performAuthedFetch(requestTemplate: Request) {
  const user = await cachedGetUser(stackClientApp);
  if (!user) {
    throw new Error("User not found");
  }

  const authHeaders = await user.getAuthHeaders();
  const mergedHeaders = new Headers();
  for (const [key, value] of Object.entries(authHeaders)) {
    if (value !== undefined) {
      mergedHeaders.set(key, value);
    }
  }

  const baseRequest = new Request(requestTemplate);
  applyHeaders(mergedHeaders, baseRequest.headers);

  const authedRequest = new Request(baseRequest, {
    headers: mergedHeaders,
  });

  return fetch(authedRequest);
}

async function logApiError(response: Response) {
  try {
    const clone = response.clone();
    const bodyText = await clone.text();
    console.error("[APIError]", {
      url: response.url,
      status: response.status,
      statusText: response.statusText,
      body: bodyText.slice(0, 2000),
    });
  } catch (error) {
    console.error("[APIError] Failed to read error body", error);
  }
}

async function shouldRetryForAuth(response: Response) {
  if (response.status === 401) {
    return true;
  }

  if (response.status === 400) {
    try {
      const clone = response.clone();
      const contentType = clone.headers.get("content-type") ?? "";
      if (contentType.toLowerCase().includes("application/json")) {
        const data = (await clone.json()) as { message?: unknown } | null;
        const message =
          typeof data === "object" && data && "message" in data
            ? data.message
            : undefined;
        if (
          typeof message === "string" &&
          message.toLowerCase().includes("invalid stack auth")
        ) {
          return true;
        }
      } else {
        const text = await clone.text();
        if (text.toLowerCase().includes("invalid stack auth")) {
          return true;
        }
      }
    } catch {
      // Swallow JSON parsing errors; we'll fall back to logging below.
    }
  }

  return false;
}

function invalidateAuthQueryCache() {
  try {
    void queryClient.invalidateQueries({ queryKey: AUTH_JSON_QUERY_KEY });
  } catch (error) {
    console.warn(
      "[fetchWithAuth] Failed to invalidate auth query cache after auth error",
      error,
    );
  }
}

const fetchWithAuth: typeof fetch = async (input, init) => {
  const requestTemplate = new Request(input, init);
  let response = await performAuthedFetch(requestTemplate);

  for (let attempt = 0; attempt < MAX_AUTH_RETRIES; attempt += 1) {
    if (!(await shouldRetryForAuth(response))) {
      break;
    }

    console.warn("[fetchWithAuth] Auth error detected; retrying with refresh", {
      status: response.status,
      attempt: attempt + 1,
    });
    resetCachedUserCache();
    invalidateAuthQueryCache();
    response = await performAuthedFetch(requestTemplate);
  }

  if (!response.ok) {
    await logApiError(response);
  }

  return response;
};

wwwOpenAPIClient.setConfig({
  baseUrl: WWW_ORIGIN,
  fetch: fetchWithAuth,
});
