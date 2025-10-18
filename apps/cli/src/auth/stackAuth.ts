import open from "open";
import { setTimeout as delay } from "node:timers/promises";
import { z } from "zod";

export interface StackAuthConfig {
  baseUrl: string;
  appUrl: string;
  projectId: string;
  publishableClientKey: string;
}

export interface PromptLoginOptions {
  onBrowserUrl?: (url: string) => void;
  onStatus?: (status: string) => void;
}

const cliInitSchema = z
  .object({
    polling_code: z.string(),
    login_code: z.string(),
  })
  .passthrough();

const cliPollSchema = z
  .object({
    status: z.string(),
    refresh_token: z.string().optional(),
  })
  .passthrough();

const accessTokenSchema = z
  .object({
    access_token: z.string(),
  })
  .passthrough();

const stackUserSchema = z
  .object({
    id: z.string(),
    display_name: z.string().nullable().optional(),
    primary_email: z.string().nullable().optional(),
    primary_email_verified: z.boolean().optional(),
    emails: z
      .array(
        z
          .object({
            email: z.string(),
            primary: z.boolean().optional(),
          })
          .passthrough(),
      )
      .optional(),
  })
  .passthrough();

export type StackUser = z.infer<typeof stackUserSchema>;

function parseWithDebug<T>(
  schema: z.ZodType<T>,
  payload: unknown,
  context: string,
): T {
  const result = schema.safeParse(payload);
  if (result.success) {
    return result.data;
  }

  const serializedIssues = JSON.stringify(result.error.issues, null, 2);
  const serializedPayload =
    typeof payload === "string"
      ? payload
      : JSON.stringify(payload, null, 2);

  throw new Error(
    `${context} validation failed.\nIssues: ${serializedIssues}\nPayload: ${serializedPayload}`,
  );
}

export class StackAuthClient {
  private readonly config: StackAuthConfig;

  constructor(config: StackAuthConfig) {
    this.config = config;
  }

  async promptCliLogin(
    options: PromptLoginOptions = {},
  ): Promise<{ refreshToken: string; loginUrl: string }> {
    const initResponse = await this.post("/api/v1/auth/cli", {
      expires_in_millis: 10 * 60 * 1000,
    });

    const initPayload = await this.safeJson(initResponse);
    const { polling_code: pollingCode, login_code: loginCode } =
      parseWithDebug(cliInitSchema, initPayload, "CLI init response");

    const loginUrl = `${this.config.appUrl}/handler/cli-auth-confirm?login_code=${encodeURIComponent(loginCode)}`;
    options.onBrowserUrl?.(loginUrl);

    try {
      await open(loginUrl, { wait: false });
    } catch (error) {
      const err = error instanceof Error ? error.message : "unknown error";
      options.onStatus?.(
        `Unable to launch browser automatically (${err}). Please open the URL manually.`,
      );
    }

    const seenStatuses = new Set<string>();
    while (true) {
      const pollResponse = await this.post("/api/v1/auth/cli/poll", {
        polling_code: pollingCode,
      });

      const pollPayload = await this.safeJson(pollResponse);
      const payload = parseWithDebug(
        cliPollSchema,
        pollPayload,
        "CLI poll response",
      );

      if (!seenStatuses.has(payload.status)) {
        seenStatuses.add(payload.status);
        options.onStatus?.(
          payload.status === "success"
            ? "Login approved! Finalizing…"
            : `Waiting for login (${payload.status})…`,
        );
      }

      if (payload.status === "success" && payload.refresh_token) {
        return { refreshToken: payload.refresh_token, loginUrl };
      }

      if (
        payload.status === "cancelled" ||
        payload.status === "error" ||
        payload.status === "failed" ||
        payload.status === "denied" ||
        payload.status === "expired"
      ) {
        throw new Error(
          `Stack Auth CLI flow ended with status "${payload.status}".`,
        );
      }

      await delay(2000);
    }
  }

  async getAccessToken(refreshToken: string): Promise<string> {
    const response = await this.post(
      "/api/v1/auth/sessions/current/refresh",
      {},
      {
        "x-stack-refresh-token": refreshToken,
      },
    );
    const payload = parseWithDebug(
      accessTokenSchema,
      await this.safeJson(response),
      "Access token response",
    );
    return payload.access_token;
  }

  async getUser(accessToken: string): Promise<StackUser> {
    const response = await this.request("GET", "/api/v1/users/me", undefined, {
      "x-stack-access-token": accessToken,
    });
    const data = await this.safeJson(response);
    return parseWithDebug(stackUserSchema, data, "Stack user response");
  }

  private async post(
    endpoint: string,
    body: Record<string, unknown>,
    extraHeaders: Record<string, string> = {},
  ): Promise<Response> {
    return this.request("POST", endpoint, body, extraHeaders);
  }

  private async request(
    method: "GET" | "POST",
    endpoint: string,
    body?: Record<string, unknown>,
    extraHeaders: Record<string, string> = {},
  ): Promise<Response> {
    const response = await fetch(`${this.config.baseUrl}${endpoint}`, {
      method,
      headers: {
        "Content-Type": "application/json",
        "x-stack-project-id": this.config.projectId,
        "x-stack-access-type": "client",
        "x-stack-publishable-client-key": this.config.publishableClientKey,
        ...extraHeaders,
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      const text = await response.text();
      throw new Error(
        `Stack Auth request to ${endpoint} failed (${response.status}): ${text}`,
      );
    }

    return response;
  }

  private async safeJson(response: Response): Promise<unknown> {
    try {
      return await response.json();
    } catch (error) {
      const err = error instanceof Error ? error.message : "Unknown error";
      throw new Error(`Failed to parse JSON response: ${err}`);
    }
  }
}
