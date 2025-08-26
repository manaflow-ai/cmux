import { getOctokit } from "./octokit.js";

export type PrBasic = {
  number: number;
  html_url: string;
  state: string; // "open" | "closed"
  draft?: boolean;
};

export type PrDetail = {
  number: number;
  html_url: string;
  state: string;
  draft?: boolean;
  merged_at: string | null;
  node_id: string;
};

export function parseRepoFromUrl(url: string): { owner?: string; repo?: string; number?: number } {
  const m = url.match(/github\.com\/(.*?)\/(.*?)\/pull\/(\d+)/i);
  if (!m) return {};
  return { owner: m[1], repo: m[2], number: parseInt(m[3] || "", 10) || undefined };
}

export async function fetchPrByHead(
  token: string,
  owner: string,
  repo: string,
  headOwner: string,
  branchName: string
): Promise<PrBasic | null> {
  const octokit = getOctokit(token);
  const head = `${headOwner}:${branchName}`;
  const { data } = await octokit.rest.pulls.list({ owner, repo, state: "all", head, per_page: 10 });
  if (!Array.isArray(data) || data.length === 0) return null;
  const pr = data[0];
  return {
    number: pr.number,
    html_url: pr.html_url,
    state: pr.state,
    draft: pr.draft ?? undefined,
  };
}

export async function fetchPrDetail(
  token: string,
  owner: string,
  repo: string,
  number: number
): Promise<PrDetail> {
  const octokit = getOctokit(token);
  const { data } = await octokit.rest.pulls.get({ owner, repo, pull_number: number });
  return {
    number: data.number,
    html_url: data.html_url,
    state: data.state,
    draft: data.draft ?? undefined,
    merged_at: data.merged_at,
    node_id: data.node_id,
  };
}

export async function createReadyPr(
  token: string,
  owner: string,
  repo: string,
  title: string,
  head: string,
  base: string,
  body: string
): Promise<PrBasic> {
  const octokit = getOctokit(token);
  const { data } = await octokit.rest.pulls.create({
    owner,
    repo,
    title,
    head,
    base,
    body,
    draft: false,
  });
  return {
    number: data.number,
    html_url: data.html_url,
    state: data.state,
    draft: data.draft ?? undefined,
  };
}

export async function createDraftPr(
  token: string,
  owner: string,
  repo: string,
  title: string,
  head: string,
  base: string,
  body: string
): Promise<PrBasic> {
  const octokit = getOctokit(token);
  const { data } = await octokit.rest.pulls.create({
    owner,
    repo,
    title,
    head,
    base,
    body,
    draft: true,
  });
  return {
    number: data.number,
    html_url: data.html_url,
    state: data.state,
    draft: data.draft ?? undefined,
  };
}

export async function markPrReady(
  token: string,
  owner: string,
  repo: string,
  number: number
): Promise<void> {
  const octokit = getOctokit(token);
  
  // GitHub's mark ready for review endpoint requires GraphQL
  // First, get the PR to obtain its node_id
  const { data: pr } = await octokit.rest.pulls.get({ 
    owner, 
    repo, 
    pull_number: number 
  });
  
  if (!pr.draft) {
    // PR is already ready for review
    return;
  }
  
  // Use GraphQL mutation to mark as ready
  await octokit.graphql(`
    mutation markPullRequestReadyForReview($pullRequestId: ID!) {
      markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
        pullRequest {
          id
          isDraft
        }
      }
    }
  `, {
    pullRequestId: pr.node_id
  });
}

export async function reopenPr(
  token: string,
  owner: string,
  repo: string,
  number: number
): Promise<void> {
  const octokit = getOctokit(token);
  await octokit.rest.pulls.update({ owner, repo, pull_number: number, state: "open" });
}

export async function mergePr(
  token: string,
  owner: string,
  repo: string,
  number: number,
  method: "squash" | "rebase" | "merge",
  commitTitle?: string,
  commitMessage?: string
): Promise<{ merged: boolean; sha?: string; message?: string; html_url?: string }> {
  const octokit = getOctokit(token);
  const { data } = await octokit.rest.pulls.merge({
    owner,
    repo,
    pull_number: number,
    merge_method: method,
    commit_title: commitTitle,
    commit_message: commitMessage,
  });
  return {
    merged: data.merged ?? false,
    sha: data.sha,
    message: data.message,
    html_url: (data as unknown as { html_url?: string }).html_url,
  };
}
