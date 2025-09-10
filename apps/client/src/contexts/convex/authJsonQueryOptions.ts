import { cachedGetUser } from "@/lib/cachedGetUser";
import { stackClientApp } from "@/lib/stack";
import { queryOptions } from "@tanstack/react-query";
import { decodeJwt } from "jose";

export type AuthJson = { accessToken: string | null } | null;

export interface StackUserLike {
  getAuthJson: () => Promise<{ accessToken: string | null }>;
}

// Default fallback refresh: 10 minutes
export const defaultAuthJsonRefreshInterval = 30 * 60 * 1000;

export function authJsonQueryOptions() {
  return queryOptions<AuthJson>({
    queryKey: ["authJson"],
    queryFn: async () => {
      const user = await cachedGetUser(stackClientApp);
      if (!user) return null;
      const authJson = await user.getAuthJson();
      return authJson ?? null;
    },
    // Dynamically refetch based on token expiry with a small buffer.
    // TanStack Query supports functions for refetchInterval in v5.
    refetchInterval: (query) => {
      const accessToken = (query.state.data as AuthJson)?.accessToken ?? null;
      if (!accessToken) return defaultAuthJsonRefreshInterval;
      try {
        const payload = decodeJwt(accessToken);
        const exp = typeof payload.exp === "number" ? payload.exp : undefined;
        if (!exp) return defaultAuthJsonRefreshInterval;
        const nowMs = Date.now();
        const expMs = exp * 1000;
        const bufferMs = 60 * 1000; // refresh 60s before expiry
        const untilRefresh = Math.max(expMs - nowMs - bufferMs, 30 * 1000); // min 30s
        return untilRefresh;
      } catch {
        return defaultAuthJsonRefreshInterval;
      }
    },
    refetchIntervalInBackground: true,
  });
}
