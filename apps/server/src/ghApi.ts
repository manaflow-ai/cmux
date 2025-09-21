import { getGitHubTokenFromKeychain } from "./utils/getGitHubToken";

interface GitHubApiError extends Error {
  status?: number;
}

// Helper functions for common GitHub API operations
export const ghApi = {
  // Fetch with GitHub authentication
  async fetchGitHub(path: string, options: RequestInit = {}): Promise<Response> {
    const token = await getGitHubTokenFromKeychain();
    
    if (!token) {
      const error = new Error("No GitHub authentication found") as GitHubApiError;
      error.status = 401;
      throw error;
    }

    const response = await fetch(`https://api.github.com${path}`, {
      ...options,
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'Authorization': `Bearer ${token}`,
        'User-Agent': 'cmux-app',
        ...options.headers,
      },
    });

    if (!response.ok) {
      const error = new Error(`GitHub API error: ${response.statusText}`) as GitHubApiError;
      error.status = response.status;
      throw error;
    }

    return response;
  },

  // Fetch all pages from GitHub API
  async fetchAllPages<T>(path: string): Promise<T[]> {
    const results: T[] = [];
    let page = 1;
    const perPage = 100;

    while (true) {
      const separator = path.includes('?') ? '&' : '?';
      const response = await this.fetchGitHub(`${path}${separator}per_page=${perPage}&page=${page}`);
      const data = await response.json() as T[];
      
      if (data.length === 0) break;
      
      results.push(...data);
      
      if (data.length < perPage) break;
      page++;
    }

    return results;
  },

  // Get current user
  async getUser(): Promise<string> {
    const response = await this.fetchGitHub('/user');
    const data = await response.json();
    return data.login;
  },

  // Get user repos
  async getUserRepos(): Promise<string[]> {
    const repos = await this.fetchAllPages<{ full_name: string }>('/user/repos');
    return repos.map(repo => repo.full_name);
  },

  // Get user organizations
  async getUserOrgs(): Promise<string[]> {
    const orgs = await this.fetchAllPages<{ login: string }>('/user/orgs');
    return orgs.map(org => org.login);
  },

  // Get organization repos
  async getOrgRepos(org: string): Promise<string[]> {
    const repos = await this.fetchAllPages<{ full_name: string }>(`/orgs/${org}/repos`);
    return repos.map(repo => repo.full_name);
  },

  // Get repo branches
  async getRepoBranches(repo: string): Promise<string[]> {
    const branches = await this.fetchAllPages<{ name: string }>(`/repos/${repo}/branches`);
    return branches.map(branch => branch.name);
  },

  // Get repo branches with last activity timestamp
  async getRepoBranchesWithActivity(repo: string): Promise<{
    name: string;
    lastCommitSha?: string;
    lastActivityAt?: number;
  }[]> {
    type BranchResp = { name: string; commit: { sha: string; url: string } };
    const branches = await this.fetchAllPages<BranchResp>(`/repos/${repo}/branches`);

    // Initialize results array with all branches to ensure none are lost
    const results: { name: string; lastCommitSha?: string; lastActivityAt?: number }[] = 
      branches.map(br => ({ name: br.name, lastCommitSha: br.commit.sha }));

    // Limit concurrent commit detail fetches to avoid rate spikes
    const concurrency = 6;
    let index = 0;

    const runNext = async (): Promise<void> => {
      const i = index++;
      if (i >= branches.length) return;
      const br = branches[i]!;
      try {
        // commit.url is absolute; extract path for fetchGitHub
        const { pathname, search } = new URL(br.commit.url);
        const resp = await this.fetchGitHub(`${pathname}${search ?? ""}`);
        const data = (await resp.json()) as {
          commit?: {
            author?: { date?: string };
            committer?: { date?: string };
          };
        };
        const dateStr = data.commit?.committer?.date ?? data.commit?.author?.date;
        const ts = dateStr ? Date.parse(dateStr) : undefined;
        // Update the existing entry with activity timestamp
        results[i] = {
          name: br.name,
          lastCommitSha: br.commit.sha,
          lastActivityAt: ts,
        };
      } catch {
        // Keep the basic branch info even if fetching details fails
        // (already initialized in results array)
      }
      await runNext();
    };

    await Promise.all(new Array(Math.min(concurrency, branches.length)).fill(0).map(() => runNext()));
    return results;
  },
};
