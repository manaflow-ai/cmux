import { ConvexHttpClient } from "convex/browser";
import { getAuthToken } from "./requestContext.js";

export const CONVEX_URL =
  process.env.VITE_CONVEX_URL || "http://127.0.0.1:9777";

// Return a Convex client bound to the current auth context
export function getConvex() {
  const auth = getAuthToken();
  if (!auth) {
    throw new Error("No auth token found");
  }
  const client = new ConvexHttpClient(CONVEX_URL);
  client.setAuth(auth);
  return client;
}

export type { ConvexHttpClient };
