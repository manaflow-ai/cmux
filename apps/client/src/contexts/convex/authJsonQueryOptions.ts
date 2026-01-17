import { cachedGetUser } from "@/lib/cachedGetUser";
import { stackClientApp } from "@/lib/stack";
import { queryOptions } from "@tanstack/react-query";

export type AuthJson = { accessToken: string | null } | null;

export interface StackUserLike {
  getAuthJson: () => Promise<{ accessToken: string | null }>;
}

// Refresh every 9 minutes to beat the ~10 minute Stack access token expiry window
export const defaultAuthJsonRefreshInterval = 9 * 60 * 1000;
const missingAuthJsonRefreshInterval = 2 * 1000;

export function authJsonQueryOptions() {
  return queryOptions<AuthJson>({
    queryKey: ["authJson"],
    queryFn: async () => {
      const user = await cachedGetUser(stackClientApp);
      if (!user) return null;
      const authJson = await user.getAuthJson();
      return authJson ?? null;
    },
    refetchInterval: (query) => {
      const accessToken = query.state.data?.accessToken;
      return accessToken
        ? defaultAuthJsonRefreshInterval
        : missingAuthJsonRefreshInterval;
    },
    refetchIntervalInBackground: true,
  });
}
