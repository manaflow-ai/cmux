const DEFAULT_GITHUB_CONNECTION_MESSAGE =
  "Connect GitHub to start a CMUX cloud workspace.";

export interface GithubCredentialErrorPayload {
  error?: string;
  detail?: string;
  code?: string;
  requiresGithubConnection?: boolean;
}

export class GithubConnectionRequiredError extends Error {
  public readonly code = "GITHUB_TOKEN_MISSING" as const;

  constructor(message: string = DEFAULT_GITHUB_CONNECTION_MESSAGE) {
    super(message);
    this.name = "GithubConnectionRequiredError";
  }
}

export const isGithubCredentialErrorPayload = (
  payload: unknown,
): payload is GithubCredentialErrorPayload => {
  if (!payload || typeof payload !== "object") {
    return false;
  }
  const candidate = payload as GithubCredentialErrorPayload;
  return (
    candidate.requiresGithubConnection === true ||
    candidate.code === "github_token_missing"
  );
};

export const getGithubCredentialErrorMessage = (
  payload?: GithubCredentialErrorPayload | string,
): string => {
  if (!payload) {
    return DEFAULT_GITHUB_CONNECTION_MESSAGE;
  }
  if (typeof payload === "string") {
    return payload || DEFAULT_GITHUB_CONNECTION_MESSAGE;
  }
  return (
    payload.detail ||
    payload.error ||
    DEFAULT_GITHUB_CONNECTION_MESSAGE
  );
};
