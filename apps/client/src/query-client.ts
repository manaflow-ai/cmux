import { convexQueryClient } from "@/contexts/convex/convex-query-client";
import { QueryClient } from "@tanstack/react-query";

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      queryKeyHashFn: convexQueryClient.hashFn(),
      queryFn: convexQueryClient.queryFn(),
    },
  },
});
convexQueryClient.connect(queryClient);
