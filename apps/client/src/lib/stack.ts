import { client as wwwOpenAPIClient } from "@cmux/www-openapi-client/client.gen";
import { StackClientApp } from "@stackframe/react";
import { useNavigate as useTanstackNavigate } from "@tanstack/react-router";
import { env } from "../client-env";
import { signalConvexAuthReady } from "../contexts/convex/convex-auth-ready";
import { convexQueryClient } from "../contexts/convex/convex-query-client";
import { cachedGetUser } from "./cachedGetUser";
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

cachedGetUser(stackClientApp).then(async (user) => {
  if (!user) {
    console.warn("[StackAuth] No user; convex auth not ready");
    signalConvexAuthReady(false);
    return;
  }
  const authJson = await user.getAuthJson();
  if (!authJson.accessToken) {
    console.warn("[StackAuth] No access token; convex auth not ready");
    signalConvexAuthReady(false);
    return;
  }
  let isFirstTime = true;
  convexQueryClient.convexClient.setAuth(
    async () => {
      // First time we get the auth token, we use the cached one. In subsequent calls, we call stack to get the latest auth token.
      if (isFirstTime) {
        isFirstTime = false;
        return authJson.accessToken;
      }
      const newAuthJson = await user.getAuthJson();
      if (!newAuthJson.accessToken) {
        console.warn("[StackAuth] No access token; convex auth not ready");
        signalConvexAuthReady(false);
        return;
      }
      return newAuthJson.accessToken;
    },
    (isAuthenticated) => {
      signalConvexAuthReady(isAuthenticated);
    }
  );
});

const fetchWithAuth = (async (request: Request) => {
  const user = await cachedGetUser(stackClientApp);
  if (!user) {
    throw new Error("User not found");
  }
  const authHeaders = await user.getAuthHeaders();
  const mergedHeaders = new Headers();
  for (const [key, value] of Object.entries(authHeaders)) {
    mergedHeaders.set(key, value);
  }
  for (const [key, value] of request instanceof Request
    ? request.headers.entries()
    : []) {
    mergedHeaders.set(key, value);
  }
  const response = await fetch(request, {
    headers: mergedHeaders,
  });
  if (!response.ok) {
    try {
      const clone = response.clone();
      const bodyText = await clone.text();
      console.error("[APIError]", {
        url: response.url,
        status: response.status,
        statusText: response.statusText,
        body: bodyText.slice(0, 2000),
      });
    } catch (e) {
      console.error("[APIError] Failed to read error body", e);
    }
  }
  return response;
}) as typeof fetch; // TODO: remove when bun types dont conflict with node types

wwwOpenAPIClient.setConfig({
  baseUrl: WWW_ORIGIN,
  fetch: fetchWithAuth,
});
