'use client';

import type { ReactNode } from "react";
import { useCallback, useMemo } from "react";
import { useStackApp } from "@stackframe/stack";
import { QueryClientProvider } from "@tanstack/react-query";
import { ConvexProviderWithAuth } from "convex/react";

import { convexReactClient } from "@/lib/convex/convex-query-client";
import { queryClient } from "@/lib/react-query/query-client";

export function ConvexClientProvider({ children }: { children: ReactNode }) {
  const stackApp = useStackApp();

  const fetchAccessToken = useMemo(
    () => stackApp.getConvexClientAuth({ tokenStore: "cookie" }),
    [stackApp],
  );

  const useAuth = useCallback(() => {
    const user = stackApp.useUser({ or: "return-null" });

    return {
      isLoading: false,
      isAuthenticated: user !== null,
      fetchAccessToken,
    };
  }, [stackApp, fetchAccessToken]);

  return (
    <QueryClientProvider client={queryClient}>
      <ConvexProviderWithAuth client={convexReactClient} useAuth={useAuth}>
        {children}
      </ConvexProviderWithAuth>
    </QueryClientProvider>
  );
}
