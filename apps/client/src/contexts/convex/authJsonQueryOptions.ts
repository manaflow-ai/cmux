import { queryOptions } from "@tanstack/react-query";
import { convexQueryClient } from "./convex-query-client";

export type AuthJson = { accessToken: string | null } | null;

export interface StackUserLike {
  getAuthJson: () => Promise<{ accessToken: string | null }>;
}

// Refresh every 30 minutes by default
export const defaultAuthJsonRefreshInterval = 30 * 60 * 1000;

export function authJsonQueryOptions(
  user: StackUserLike | null | undefined,
  refreshMs: number = defaultAuthJsonRefreshInterval
) {
  return queryOptions<AuthJson>({
    queryKey: ["authJson"],
    queryFn: async () => {
      if (!user) return null;
      const authJson = await user.getAuthJson();
      if (authJson.accessToken) {
        convexQueryClient.convexClient.setAuth(
          async () => authJson.accessToken
        );
      }
      return authJson ?? null;
    },
    refetchInterval: refreshMs,
    refetchIntervalInBackground: true,
  });
}
