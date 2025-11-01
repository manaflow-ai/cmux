import { cachedGetUser } from "@/lib/cachedGetUser";
import { stackClientApp } from "@/lib/stack";
import { queryOptions } from "@tanstack/react-query";

export type AuthJson = { accessToken: string | null } | null;

export interface StackUserLike {
  getAuthJson: () => Promise<{ accessToken: string | null }>;
}

export const AUTH_JSON_QUERY_KEY = ["authJson"] as const;

// Refresh every 9 minutes to beat the ~10 minute Stack access token expiry window
export const defaultAuthJsonRefreshInterval = 9 * 60 * 1000;

export function authJsonQueryOptions() {
  return queryOptions<AuthJson>({
    queryKey: AUTH_JSON_QUERY_KEY,
    queryFn: async () => {
      const user = await cachedGetUser(stackClientApp);
      if (!user) return null;
      const authJson = await user.getAuthJson();
      return authJson ?? null;
    },
    refetchInterval: defaultAuthJsonRefreshInterval,
    refetchIntervalInBackground: true,
  });
}
