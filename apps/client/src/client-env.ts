type EnvShape = {
  NEXT_PUBLIC_CONVEX_URL: string;
  NEXT_PUBLIC_STACK_PROJECT_ID: string;
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: string;
  NEXT_PUBLIC_GITHUB_APP_SLUG?: string;
  NEXT_PUBLIC_WWW_ORIGIN: string;
};

type ImportMetaLike = { env?: Record<string, string | undefined> };
type NodeProcessLike = { env?: Record<string, string | undefined> };

const metaEnv = (typeof import.meta !== "undefined"
  ? ((import.meta as unknown as ImportMetaLike).env ?? {})
  : {}) as Record<string, string | undefined>;

const nodeEnv = (typeof process !== "undefined"
  ? ((process as unknown as NodeProcessLike).env ?? {})
  : {}) as Record<string, string | undefined>;

function read(key: keyof EnvShape): string | undefined {
  return nodeEnv[key as string] ?? metaEnv[key as string];
}

function required(key: keyof EnvShape): string {
  const val = read(key);
  if (!val) throw new Error(`Missing required env var: ${String(key)}`);
  return val;
}

export const env: EnvShape = {
  NEXT_PUBLIC_CONVEX_URL: required("NEXT_PUBLIC_CONVEX_URL"),
  NEXT_PUBLIC_STACK_PROJECT_ID: required("NEXT_PUBLIC_STACK_PROJECT_ID"),
  NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: required("NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"),
  NEXT_PUBLIC_GITHUB_APP_SLUG: read("NEXT_PUBLIC_GITHUB_APP_SLUG"),
  NEXT_PUBLIC_WWW_ORIGIN: read("NEXT_PUBLIC_WWW_ORIGIN") ?? "http://localhost:9779",
};

