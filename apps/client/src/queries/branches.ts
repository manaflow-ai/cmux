import { waitForConnectedSocket } from "@/contexts/socket/socket-boot";
import { queryOptions } from "@tanstack/react-query";
import type { GitHubBranchesResponse } from "@cmux/shared";

export function branchesQueryOptions({
  teamSlugOrId,
  repoFullName,
}: {
  teamSlugOrId: string;
  repoFullName: string;
}) {
  const normalizedRepoFullName = repoFullName.trim();
  return queryOptions<GitHubBranchesResponse>({
    queryKey: ["branches", teamSlugOrId, normalizedRepoFullName],
    queryFn: async () => {
      const socket = await waitForConnectedSocket();
      return await new Promise<GitHubBranchesResponse>((resolve, reject) => {
        socket.emit(
          "github-fetch-branches",
          { teamSlugOrId, repo: normalizedRepoFullName },
          (response: GitHubBranchesResponse) => {
            if (response.success) {
              resolve(response);
            } else {
              reject(new Error(response.error || "Failed to load branches"));
            }
          }
        );
      });
    },
    staleTime: 10_000,
  });
}
