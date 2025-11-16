import { cachedGetUser } from "@/lib/cachedGetUser";
import { stackClientApp } from "@/lib/stack";
import { queryOptions } from "@tanstack/react-query";

export type AuthJson = { accessToken: string | null } | null;

export interface StackUserLike {
  getAuthJson: () => Promise<{ accessToken: string | null }>;
}

// Refresh every 5 minutes to ensure we always have a fresh token
// Stack access tokens typically expire after 10 minutes, so refreshing at 5 minutes
// provides a good safety margin and prevents token expiration issues
export const defaultAuthJsonRefreshInterval = 5 * 60 * 1000;

export function authJsonQueryOptions() {
  return queryOptions<AuthJson>({
    queryKey: ["authJson"],
    queryFn: async () => {
      const user = await cachedGetUser(stackClientApp);
      if (!user) return null;
      const authJson = await user.getAuthJson();
      return authJson ?? null;
    },
    refetchInterval: defaultAuthJsonRefreshInterval,
    refetchIntervalInBackground: true,
    staleTime: 4 * 60 * 1000, // Consider data stale after 4 minutes
    gcTime: 10 * 60 * 1000, // Keep in cache for 10 minutes
  });
}
