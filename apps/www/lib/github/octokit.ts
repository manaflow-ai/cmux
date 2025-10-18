import { Octokit } from "octokit";

const USER_AGENT = "cmux-www-pr-viewer";

export function createGitHubClient(): Octokit {
  const authToken = process.env.GITHUB_TOKEN;

  return new Octokit({
    auth: authToken,
    userAgent: USER_AGENT,
    request: {
      timeout: 20_000,
    },
  });
}
