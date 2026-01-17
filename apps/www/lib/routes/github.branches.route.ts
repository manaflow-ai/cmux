import { stackServerAppJs } from "@/lib/utils/stack";
import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import { Octokit } from "octokit";

export const githubBranchesRouter = new OpenAPIHono();

// Schema for branch data
const GithubBranch = z
  .object({
    name: z.string(),
    lastCommitSha: z.string().optional(),
    lastCommitDate: z.string().optional(),
    isDefault: z.boolean().optional(),
  })
  .openapi("GithubBranch");

// --- Default Branch Endpoint (fast - single API call) ---

const DefaultBranchQuery = z
  .object({
    repo: z.string().min(1).openapi({ description: "Repository full name (owner/repo)" }),
  })
  .openapi("GithubDefaultBranchQuery");

const DefaultBranchResponse = z
  .object({
    defaultBranch: z.string().nullable(),
    error: z.string().nullable(),
  })
  .openapi("GithubDefaultBranchResponse");

githubBranchesRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/default-branch",
    tags: ["Integrations"],
    summary: "Get the default branch for a repository (fast - single API call)",
    request: { query: DefaultBranchQuery },
    responses: {
      200: {
        description: "Default branch response",
        content: {
          "application/json": {
            schema: DefaultBranchResponse,
          },
        },
      },
      401: { description: "Unauthorized" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const { repo } = c.req.valid("query");

    try {
      const githubAccount = await user.getConnectedAccount("github");
      if (!githubAccount) {
        return c.json({ defaultBranch: null, error: "GitHub account not connected" }, 200);
      }

      const { accessToken } = await githubAccount.getAccessToken();
      if (!accessToken || accessToken.trim().length === 0) {
        return c.json({ defaultBranch: null, error: "GitHub access token not found" }, 200);
      }

      const octokit = new Octokit({ auth: accessToken.trim() });
      const [owner, repoName] = repo.split("/");

      const { data } = await octokit.request("GET /repos/{owner}/{repo}", {
        owner: owner!,
        repo: repoName!,
      });

      return c.json({ defaultBranch: data.default_branch, error: null }, 200);
    } catch (error) {
      console.error("[github.branches] Error getting default branch:", error);
      return c.json({
        defaultBranch: null,
        error: error instanceof Error ? error.message : "Failed to get default branch",
      }, 200);
    }
  }
);

// --- Branches List Endpoint (with optional search) ---

const BranchesQuery = z
  .object({
    repo: z.string().min(1).openapi({ description: "Repository full name (owner/repo)" }),
    search: z
      .string()
      .trim()
      .optional()
      .openapi({ description: "Optional search term to filter branches by name" }),
    limit: z.coerce
      .number()
      .min(1)
      .max(100)
      .default(30)
      .optional()
      .openapi({ description: "Max branches to return (default 30, max 100)" }),
    offset: z.coerce
      .number()
      .min(0)
      .default(0)
      .optional()
      .openapi({ description: "Offset for pagination (number of branches to skip)" }),
  })
  .openapi("GithubBranchesQuery");

const BranchesResponse = z
  .object({
    branches: z.array(GithubBranch),
    defaultBranch: z.string().nullable(),
    error: z.string().nullable(),
    nextOffset: z.number().optional(),
    hasMore: z.boolean(),
  })
  .openapi("GithubBranchesResponse");

type BranchesResponseType = z.infer<typeof BranchesResponse>;

const branchesErrorResponse = (error: string): BranchesResponseType => ({
  branches: [],
  defaultBranch: null,
  error,
  hasMore: false,
});

githubBranchesRouter.openapi(
  createRoute({
    method: "get" as const,
    path: "/integrations/github/branches",
    tags: ["Integrations"],
    summary: "List branches for a repository with optional search filter",
    request: { query: BranchesQuery },
    responses: {
      200: {
        description: "Branches list response",
        content: {
          "application/json": {
            schema: BranchesResponse,
          },
        },
      },
      401: { description: "Unauthorized" },
    },
  }),
  async (c) => {
    const user = await stackServerAppJs.getUser({ tokenStore: c.req.raw });
    if (!user) {
      return c.text("Unauthorized", 401);
    }

    const { repo, search, limit = 30, offset = 0 } = c.req.valid("query");

    try {
      const githubAccount = await user.getConnectedAccount("github");
      if (!githubAccount) {
        return c.json(branchesErrorResponse("GitHub account not connected"), 200);
      }

      const { accessToken } = await githubAccount.getAccessToken();
      if (!accessToken || accessToken.trim().length === 0) {
        return c.json(branchesErrorResponse("GitHub access token not found"), 200);
      }

      const octokit = new Octokit({ auth: accessToken.trim() });
      const [owner, repoName] = repo.split("/");
      if (!owner || !repoName) {
        return c.json(branchesErrorResponse("Invalid repository format"), 200);
      }

      const normalizedSearch = search?.trim().toLowerCase() ?? "";
      const shouldFilter = normalizedSearch.length > 0;

      const graphqlResponse = z.object({
        repository: z
          .object({
            defaultBranchRef: z.object({ name: z.string() }).nullable(),
            refs: z.object({
              edges: z.array(
                z.object({
                  cursor: z.string(),
                  node: z.object({
                    name: z.string(),
                    target: z.object({
                      oid: z.string(),
                      committedDate: z.string().optional(),
                    }),
                  }),
                })
              ),
              pageInfo: z.object({
                hasNextPage: z.boolean(),
                endCursor: z.string().nullable(),
              }),
            }),
          })
          .nullable(),
      });

      // Note: TAG_COMMIT_DATE only works for tag refs. For branch refs (refs/heads/),
      // it defaults to alphabetical ordering. We fetch without explicit ordering
      // and sort by commit date ourselves after fetching.
      const query = `
        query($owner: String!, $repo: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            defaultBranchRef {
              name
            }
            refs(refPrefix: "refs/heads/", first: $first, after: $after) {
              edges {
                cursor
                node {
                  name
                  target {
                    oid
                    ... on Commit {
                      committedDate
                    }
                  }
                }
              }
              pageInfo {
                hasNextPage
                endCursor
              }
            }
          }
        }
      `;

      // For sorting by commit date, we fetch branches and sort client-side.
      // We need to fetch at least (offset + limit) branches to return the requested page.
      const targetCount = offset + limit;
      const fetchSize = Math.max(targetCount, 50);

      const allBranches: Array<z.infer<typeof GithubBranch>> = [];
      let defaultBranchName: string | null = null;
      let afterCursor: string | null = null;
      let githubHasMore = true;

      // For search, cap at 200 branches max to keep it fast
      const maxBranchesToFetch = shouldFilter ? 200 : Math.max(fetchSize, 100);
      let totalFetched = 0;

      while (allBranches.length < targetCount && githubHasMore && totalFetched < maxBranchesToFetch) {
        const rawResponse: unknown = await octokit.graphql(query, {
          owner,
          repo: repoName,
          first: fetchSize,
          after: afterCursor ?? null,
        });

        const parsed = graphqlResponse.parse(rawResponse);
        const repoData = parsed.repository;
        if (!repoData) {
          return c.json(branchesErrorResponse("Repository not found"), 200);
        }

        if (defaultBranchName === null) {
          defaultBranchName = repoData.defaultBranchRef?.name ?? null;
        }

        const edges = repoData.refs.edges;
        for (const edge of edges) {
          const name = edge.node.name;
          if (shouldFilter && !name.toLowerCase().includes(normalizedSearch)) {
            continue;
          }

          allBranches.push({
            name,
            lastCommitSha: edge.node.target.oid,
            lastCommitDate: edge.node.target.committedDate,
            isDefault: name === defaultBranchName,
          });
        }

        totalFetched += edges.length;
        githubHasMore = repoData.refs.pageInfo.hasNextPage;
        const endCursor = repoData.refs.pageInfo.endCursor;

        if (!githubHasMore || !endCursor) {
          break;
        }

        afterCursor = endCursor;
      }

      // Sort branches by commit date (most recent first)
      allBranches.sort((a, b) => {
        // Put branches without commit date at the end
        if (!a.lastCommitDate && !b.lastCommitDate) return 0;
        if (!a.lastCommitDate) return 1;
        if (!b.lastCommitDate) return -1;
        // Sort by date descending (most recent first)
        return new Date(b.lastCommitDate).getTime() - new Date(a.lastCommitDate).getTime();
      });

      // Return the requested slice (offset to offset+limit)
      const branches = allBranches.slice(offset, offset + limit);

      const hasMore = allBranches.length > offset + limit || githubHasMore;
      const nextOffset = hasMore ? offset + limit : undefined;

      return c.json({
        branches,
        defaultBranch: defaultBranchName,
        error: null,
        nextOffset,
        hasMore,
      }, 200);
    } catch (error) {
      console.error("[github.branches] Error fetching branches:", error);
      const message = error instanceof Error ? error.message : "Failed to fetch branches";
      return c.json(branchesErrorResponse(message), 200);
    }
  }
);
