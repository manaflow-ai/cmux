export class GithubApiError extends Error {
  readonly status: number;
  readonly documentationUrl?: string;

  constructor(message: string, options: { status: number; documentationUrl?: string }) {
    super(message);
    this.name = "GithubApiError";
    this.status = options.status;
    this.documentationUrl = options.documentationUrl;
  }
}

export function isGithubApiError(error: unknown): error is GithubApiError {
  return error instanceof GithubApiError;
}
