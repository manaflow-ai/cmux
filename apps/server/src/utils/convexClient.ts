import { convexClientCache } from "@cmux/shared/node/convex-cache";
import { ConvexHttpClient } from "convex/browser";
import { decodeJwt } from "jose";
import { getAuthToken } from "./requestContext";
import { env } from "./server-env";

// Return a Convex client bound to the current auth context
export function getConvex() {
  const auth = getAuthToken();
  if (!auth) {
    throw new Error("No auth token found");
  }

  // Try to get from cache first
  const cachedClient = convexClientCache.get(auth, env.NEXT_PUBLIC_CONVEX_URL);
  if (cachedClient) {
    return cachedClient;
  }

  // Validate token expiration before creating a new client
  try {
    const jwt = decodeJwt(auth);
    const now = Date.now() / 1000;

    if (jwt.exp && jwt.exp < now) {
      const expiredSeconds = Math.floor(now - jwt.exp);
      throw new Error(
        `Auth token expired ${expiredSeconds} seconds ago. ` +
        `Client must refresh the token and retry the request.`
      );
    }
  } catch (error) {
    if (error instanceof Error && error.message.includes("expired")) {
      throw error;
    }
    console.warn("Failed to decode/validate JWT token:", error);
    // Continue anyway - let Convex validate the token
  }

  // Create new client and cache it
  const client = new ConvexHttpClient(env.NEXT_PUBLIC_CONVEX_URL);
  client.setAuth(auth);
  convexClientCache.set(auth, env.NEXT_PUBLIC_CONVEX_URL, client);
  return client;
}

export type { ConvexHttpClient };
