import { StackClientInterface } from "@stackframe/stack-shared";
import { RefreshToken } from "@stackframe/stack-shared/dist/sessions";
import { decodeJwt } from "jose";

type StackAuthPayload = {
  accessToken?: string | null;
  refreshToken?: string | null;
  [key: string]: unknown;
};

export interface EnsureStackAuthOptions {
  authJson?: string;
  accessToken?: string | null;
  refreshBufferSeconds?: number;
  refreshAccessToken?: (refreshToken: string) => Promise<string | null>;
}

export interface EnsureStackAuthResult {
  accessToken: string;
  authJson: string;
  updated: boolean;
  payload: StackAuthPayload;
}

const DEFAULT_REFRESH_BUFFER_SECONDS = 60;

export class StackAuthError extends Error {
  readonly userMessage: string;

  constructor(message: string, options?: { userMessage?: string }) {
    super(message);
    this.name = "StackAuthError";
    this.userMessage = options?.userMessage ?? "Authentication expired. Please sign in again.";
  }
}

function normalizeBaseUrl(raw?: string): string {
  if (!raw) {
    return "https://api.stack-auth.com";
  }
  return raw.endsWith("/") ? raw.slice(0, -1) : raw;
}

let cachedClient: StackClientInterface | null = null;

function getStackClient(): StackClientInterface {
  if (cachedClient) {
    return cachedClient;
  }

  const projectId =
    process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??
    process.env.STACK_PROJECT_ID ??
    process.env.STACK_PROJECT_ID_SERVER;
  if (!projectId) {
    throw new StackAuthError("Missing Stack project id configuration");
  }

  const publishableClientKey =
    process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??
    process.env.STACK_PUBLISHABLE_CLIENT_KEY ??
    process.env.STACK_PUBLISHABLE_CLIENT_KEY_SERVER;
  if (!publishableClientKey) {
    throw new StackAuthError("Missing Stack publishable client key configuration");
  }

  const baseUrl = normalizeBaseUrl(
    process.env.NEXT_PUBLIC_SERVER_STACK_API_URL ??
      process.env.NEXT_PUBLIC_STACK_API_URL_SERVER ??
      process.env.STACK_API_URL_SERVER ??
      process.env.NEXT_PUBLIC_STACK_API_URL ??
      process.env.STACK_API_URL ??
      process.env.NEXT_PUBLIC_STACK_URL
  );

  cachedClient = new StackClientInterface({
    getBaseUrl: () => baseUrl,
    projectId,
    publishableClientKey,
    extraRequestHeaders: {},
    clientVersion: "cmux-server",
    prepareRequest: async () => {
      // no-op hook required by interface
    },
  });

  return cachedClient;
}

function parseAuthJson(authJson?: string): StackAuthPayload {
  if (!authJson) {
    throw new StackAuthError("Missing Stack auth header payload");
  }

  try {
    const parsed = JSON.parse(authJson) as StackAuthPayload;
    return parsed;
  } catch (error) {
    throw new StackAuthError("Failed to parse Stack auth header payload", {
      userMessage: "Authentication data invalid. Please sign in again.",
    });
  }
}

function isAccessTokenExpiringSoon(accessToken: string, bufferSeconds: number): boolean {
  try {
    const payload = decodeJwt(accessToken);
    if (!payload.exp) {
      // If no expiry is present, treat the token as valid until proven otherwise.
      return false;
    }
    const nowSeconds = Math.floor(Date.now() / 1000);
    return payload.exp <= nowSeconds + bufferSeconds;
  } catch (error) {
    throw new StackAuthError("Failed to decode Stack access token", {
      userMessage: "Authentication expired. Please sign in again.",
    });
  }
}

async function defaultRefreshAccessToken(refreshToken: string): Promise<string | null> {
  const client = getStackClient();
  const refreshed = await client.fetchNewAccessToken(new RefreshToken(refreshToken));
  return refreshed?.token ?? null;
}

export async function ensureStackAuthTokensFresh(
  options: EnsureStackAuthOptions
): Promise<EnsureStackAuthResult> {
  const payload = parseAuthJson(options.authJson);
  const accessToken =
    (typeof payload.accessToken === "string" && payload.accessToken) ||
    options.accessToken ||
    null;

  if (!accessToken) {
    throw new StackAuthError("Missing Stack access token", {
      userMessage: "Authentication required. Please sign in again.",
    });
  }

  const bufferSeconds = options.refreshBufferSeconds ?? DEFAULT_REFRESH_BUFFER_SECONDS;
  const needsRefresh = isAccessTokenExpiringSoon(accessToken, bufferSeconds);

  if (!needsRefresh) {
    if (payload.accessToken !== accessToken) {
      payload.accessToken = accessToken;
      const authJson = JSON.stringify(payload);
      return { accessToken, authJson, updated: true, payload };
    }
    return { accessToken, authJson: options.authJson ?? JSON.stringify(payload), updated: false, payload };
  }

  const refreshToken =
    typeof payload.refreshToken === "string" && payload.refreshToken
      ? payload.refreshToken
      : null;

  if (!refreshToken) {
    throw new StackAuthError("Missing Stack refresh token", {
      userMessage: "Session expired. Please sign in again.",
    });
  }

  const refreshFn = options.refreshAccessToken ?? defaultRefreshAccessToken;
  const newAccessToken = await refreshFn(refreshToken);
  if (!newAccessToken) {
    throw new StackAuthError("Failed to refresh Stack access token", {
      userMessage: "Session expired. Please sign in again.",
    });
  }

  payload.accessToken = newAccessToken;
  const authJson = JSON.stringify(payload);

  return {
    accessToken: newAccessToken,
    authJson,
    updated: true,
    payload,
  };
}

export function resetStackClientForTests(): void {
  cachedClient = null;
}
