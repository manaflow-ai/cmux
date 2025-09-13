import { githubPrivateKey } from "@/lib/utils/githubPrivateKey";
import { env } from "@/lib/utils/www-env";
import { api } from "@cmux/convex/api";
import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import { ConvexHttpClient } from "convex/browser";
import { Octokit } from "octokit";
import { createAppAuth } from "@octokit/auth-app";

const TEAM = process.env.CMUX_TEAM_SLUG || "manaflow";
const PR_URL = process.env.CMUX_PR_URL || "https://github.com/manaflow-ai/cmux/pull/255";

async function main() {
  const m = PR_URL.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/i);
  if (!m) throw new Error("Invalid PR URL");
  const owner = m[1];
  const repo = m[2];
  const number = Number(m[3]);

  const { accessToken } = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
  const convex = new ConvexHttpClient(env.NEXT_PUBLIC_CONVEX_URL);
  convex.setAuth(accessToken);

  const connections = await convex.query(api.github.listProviderConnections, {
    teamSlugOrId: TEAM,
  });
  // Find installation matching the owner
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

  const prRes = await octokit.request("GET /repos/{owner}/{repo}/pulls/{pull_number}", {
    owner,
    repo,
    pull_number: number,
  });

  type Pr = {
    id: number;
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
  const pr = prRes.data as Pr;
  const ts = (s?: string | null) => (s ? Date.parse(s) : undefined);
  await convex.mutation(api.github_prs.upsertFromServer, {
    teamSlugOrId: TEAM,
    installationId: target.installationId,
    repoFullName: `${owner}/${repo}`,
    number,
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

  console.log("Backfill complete for", `${owner}/${repo}#${number}`);
}

void main();
