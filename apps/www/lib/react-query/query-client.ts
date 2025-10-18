import { convexQueryClient } from "@/lib/convex/convex-query-client";
import { QueryClient } from "@tanstack/react-query";

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      queryKeyHashFn: convexQueryClient.hashFn(),
      queryFn: convexQueryClient.queryFn(),
      staleTime: 30_000,
    },
  },
});

convexQueryClient.connect(queryClient);
