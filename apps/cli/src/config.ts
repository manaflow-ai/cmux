import { z } from "zod";

const rawEnvSchema = z.object({
  STACK_APP_URL: z.string().url().optional(),
  STACK_BASE_URL: z.string().url().optional(),
  STACK_PROJECT_ID: z.string().trim().min(1).optional(),
  STACK_PUBLISHABLE_CLIENT_KEY: z.string().trim().min(1).optional(),
  NEXT_PUBLIC_STACK_PROJECT_ID: z.string().trim().min(1).optional(),
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z
    .string()
    .trim()
    .min(1)
    .optional(),
  NEXT_PUBLIC_WWW_ORIGIN: z.string().trim().min(1).optional(),
  CMUX_WWW_ORIGIN: z.string().trim().min(1).optional(),
  STACK_CLI_TEAM_SLUG_OR_ID: z.string().trim().min(1).optional(),
  CMUX_TEAM_SLUG_OR_ID: z.string().trim().min(1).optional(),
  NEXT_PUBLIC_CONVEX_URL: z.string().trim().min(1).optional(),
  CMUX_CONVEX_URL: z.string().trim().min(1).optional(),
});

const rawEnv = rawEnvSchema.parse(process.env);

const coalesce = (...values: Array<string | undefined>): string | undefined => {
  for (const value of values) {
    if (value && value.length > 0) {
      return value;
    }
  }
  return undefined;
};

const normalizeUrl = (value: string, label: string): string => {
  try {
    const url = new URL(value);
    const normalized =
      url.protocol === "http:" || url.protocol === "https:"
        ? url.toString().replace(/\/+$/, "")
        : value.replace(/\/+$/, "");
    return normalized.length > 0 ? normalized : value;
  } catch (_error) {
    throw new Error(`Invalid URL provided for ${label}: ${value}`);
  }
};

const projectId = coalesce(
  rawEnv.STACK_PROJECT_ID,
  rawEnv.NEXT_PUBLIC_STACK_PROJECT_ID,
);
if (!projectId) {
  throw new Error(
    "Missing STACK_PROJECT_ID or NEXT_PUBLIC_STACK_PROJECT_ID environment variable.",
  );
}

const publishableClientKey = coalesce(
  rawEnv.STACK_PUBLISHABLE_CLIENT_KEY,
  rawEnv.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY,
);
if (!publishableClientKey) {
  throw new Error(
    "Missing STACK_PUBLISHABLE_CLIENT_KEY or NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY environment variable.",
  );
}

const convexUrl = coalesce(
  rawEnv.NEXT_PUBLIC_CONVEX_URL,
  rawEnv.CMUX_CONVEX_URL,
);
if (!convexUrl) {
  throw new Error(
    "Missing NEXT_PUBLIC_CONVEX_URL or CMUX_CONVEX_URL environment variable.",
  );
}

const wwwOrigin = coalesce(
  rawEnv.NEXT_PUBLIC_WWW_ORIGIN,
  rawEnv.CMUX_WWW_ORIGIN,
);
if (!wwwOrigin) {
  throw new Error(
    "Missing NEXT_PUBLIC_WWW_ORIGIN or CMUX_WWW_ORIGIN environment variable.",
  );
}

const appUrl = coalesce(rawEnv.STACK_APP_URL, wwwOrigin) ?? wwwOrigin;

export const cliConfig = {
  stack: {
    baseUrl: normalizeUrl(
      rawEnv.STACK_BASE_URL ?? "https://api.stack-auth.com",
      "STACK_BASE_URL",
    ),
    appUrl: normalizeUrl(appUrl, "STACK_APP_URL"),
    projectId,
    publishableClientKey,
  },
  wwwOrigin: normalizeUrl(wwwOrigin, "NEXT_PUBLIC_WWW_ORIGIN"),
  convexUrl: normalizeUrl(convexUrl, "NEXT_PUBLIC_CONVEX_URL"),
  defaultTeamSlugOrId:
    rawEnv.CMUX_TEAM_SLUG_OR_ID ?? rawEnv.STACK_CLI_TEAM_SLUG_OR_ID ?? null,
};

export type CLIConfig = typeof cliConfig;
