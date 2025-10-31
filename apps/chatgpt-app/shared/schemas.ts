import { z } from "zod";

export const agentPresetValues = [
  "default",
  "stack",
  "llm-heavy",
] as const;

export const CreateTaskInputSchema = z
  .object({
    teamSlugOrId: z.string(),
    taskText: z.string().min(1, "Task text is required"),
    repoFullName: z.string().optional(),
    environmentId: z.string().optional(),
    agentPreset: z.enum(agentPresetValues).default("default"),
    openPreview: z.boolean().default(true),
  })
  .describe("Parameters accepted by the cmux.create_task tool");

export type CreateTaskInput = z.infer<typeof CreateTaskInputSchema>;

export const CmuxWorkspaceUrlSchema = z.object({
  url: z.string().url(),
  label: z.string().optional(),
  port: z.number().int().positive().optional(),
  preflightStatus: z
    .enum(["pending", "ready", "resuming", "error"])
    .default("pending"),
});

export type CmuxWorkspaceUrl = z.infer<typeof CmuxWorkspaceUrlSchema>;

export const CmuxWorkspaceResultSchema = z.object({
  type: z.literal("cmux_workspace"),
  task: z.object({
    id: z.string(),
    url: z.string().url(),
    title: z.string(),
  }),
  run: z.object({
    id: z.string(),
    agents: z.array(
      z.object({
        name: z.string(),
        status: z.enum(["pending", "running", "succeeded", "failed"]),
        summary: z.string().optional(),
      }),
    ),
    lastUpdatedAt: z.string().optional(),
  }),
  workspace: z.object({
    vscode: CmuxWorkspaceUrlSchema,
    previews: z.array(CmuxWorkspaceUrlSchema).default([]),
    instanceId: z.string().optional(),
  }),
  pollToken: z.string().optional(),
  message: z.string().optional(),
});

export type CmuxWorkspaceResult = z.infer<typeof CmuxWorkspaceResultSchema>;

export const PollTaskInputSchema = z
  .object({
    pollToken: z.string(),
  })
  .describe("Parameters accepted by the cmux.poll_task tool");

export type PollTaskInput = z.infer<typeof PollTaskInputSchema>;

export const PollTaskResultSchema = z.object({
  type: z.literal("cmux_workspace_status"),
  run: CmuxWorkspaceResultSchema.shape.run,
  workspace: CmuxWorkspaceResultSchema.shape.workspace,
  message: z.string().optional(),
});

export type PollTaskResult = z.infer<typeof PollTaskResultSchema>;
