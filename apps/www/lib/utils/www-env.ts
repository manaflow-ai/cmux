import { createEnv } from "@t3-oss/env-core";
import { z } from "zod";

export const env = createEnv({
  clientPrefix: "NEXT_PUBLIC_",
  server: {
    // Stack server-side env
    STACK_SECRET_SERVER_KEY: z.string().min(1),
    STACK_SUPER_SECRET_ADMIN_KEY: z.string().min(1),
    STACK_DATA_VAULT_SECRET: z.string().min(32), // For secure DataBook storage
    // GitHub App
    CMUX_GITHUB_APP_ID: z.string().min(1),
    CMUX_GITHUB_APP_PRIVATE_KEY: z.string().min(1),
    // Morph
    MORPH_API_KEY: z.string().min(1),
    CONVEX_DEPLOY_KEY: z.string().min(1),
    ANTHROPIC_API_KEY: z.string().min(1),
    CMUX_TASK_RUN_JWT_SECRET: z.string().min(1),
  },
  client: {
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().min(1),
    NEXT_PUBLIC_CONVEX_URL: z.string().min(1),
  },
  runtimeEnv: process.env,
  emptyStringAsUndefined: true,
});
