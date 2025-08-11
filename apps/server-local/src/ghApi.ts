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
};
