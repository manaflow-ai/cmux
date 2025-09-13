import { githubPrivateKey } from "@/lib/utils/githubPrivateKey";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import { ConvexHttpClient } from "convex/browser";
import { Octokit } from "octokit";
import { createAppAuth } from "@octokit/auth-app";

const TEAM = process.env.CMUX_TEAM_SLUG || "manaflow";
const REPO = process.env.CMUX_REPO || "manaflow-ai/cmux";
const STATE = (process.env.CMUX_STATE as "open" | "closed" | "all") || "all";
const MAX_PAGES = Number(process.env.CMUX_MAX_PAGES || 50);

async function main() {
  const [owner, repo] = REPO.split("/", 2);
  if (!owner || !repo) throw new Error("Invalid repo name");

  const { accessToken } = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
  const convex = new ConvexHttpClient(env.NEXT_PUBLIC_CONVEX_URL);
  convex.setAuth(accessToken);

  const connections = await convex.query(api.github.listProviderConnections, {
    teamSlugOrId: TEAM,
  });
  const target = connections.find(
    (c) => (c.isActive ?? true) && (c.accountLogin ?? "").toLowerCase() === owner.toLowerCase()
  );
  if (!target) throw new Error(`No installation found for owner ${owner}`);

  const octokit = new Octokit({
    authStrategy: createAppAuth,
    auth: {
      appId: env.CMUX_GITHUB_APP_ID,
      privateKey: githubPrivateKey,
      installationId: target.installationId,
    },
  });

  type Pull = {
    id: number;
    number: number;
    title: string;
    state: string;
    merged?: boolean;
    draft?: boolean;
    user?: { login?: string; id?: number } | null;
    html_url?: string;
    base?: { ref?: string; sha?: string; repo?: { id?: number } };
    head?: { ref?: string; sha?: string };
    created_at?: string;
    updated_at?: string;
    closed_at?: string | null;
    merged_at?: string | null;
    comments?: number;
    review_comments?: number;
    commits?: number;
    additions?: number;
    deletions?: number;
    changed_files?: number;
  };
  const ts = (s?: string | null) => (s ? Date.parse(s) : undefined);

  let page = 1;
  let count = 0;
  while (page <= MAX_PAGES) {
    const res = await octokit.request("GET /repos/{owner}/{repo}/pulls", {
      owner,
      repo,
      state: STATE,
      per_page: 100,
      page,
      sort: "updated",
      direction: "desc",
    });
    const items = (res.data as unknown as Pull[]) || [];
    if (items.length === 0) break;
    for (const pr of items) {
      await convex.mutation(api.github_prs.upsertFromServer, {
        teamSlugOrId: TEAM,
        installationId: target.installationId,
        repoFullName: `${owner}/${repo}`,
        number: pr.number,
        record: {
          providerPrId: pr.id,
          repositoryId: pr.base?.repo?.id,
          title: pr.title,
          state: pr.state === "closed" ? "closed" : "open",
          merged: !!pr.merged,
          draft: !!pr.draft,
          authorLogin: pr.user?.login ?? undefined,
          authorId: pr.user?.id ?? undefined,
          htmlUrl: pr.html_url ?? undefined,
          baseRef: pr.base?.ref ?? undefined,
          headRef: pr.head?.ref ?? undefined,
          baseSha: pr.base?.sha ?? undefined,
          headSha: pr.head?.sha ?? undefined,
          createdAt: ts(pr.created_at),
          updatedAt: ts(pr.updated_at),
          closedAt: ts(pr.closed_at ?? undefined),
          mergedAt: ts(pr.merged_at ?? undefined),
          commentsCount: pr.comments,
          reviewCommentsCount: pr.review_comments,
          commitsCount: pr.commits,
          additions: pr.additions,
          deletions: pr.deletions,
          changedFiles: pr.changed_files,
        },
      });
      count++;
    }
    if (items.length < 100) break;
    page++;
  }
  console.log(`Backfilled ${count} PRs for ${owner}/${repo}`);
}

void main();

