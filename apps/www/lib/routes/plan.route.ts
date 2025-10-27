import { getAccessTokenFromRequest } from "@/lib/utils/auth";
import { mergeApiKeysWithEnv } from "@/lib/utils/branch-name-generator";
import { getConvex } from "@/lib/utils/get-convex";
import { verifyTeamAccess } from "@/lib/utils/team-verification";
import { api } from "@cmux/convex/api";
import { createOpenAI } from "@ai-sdk/openai";
import { OpenAPIHono, createRoute, z } from "@hono/zod-openapi";
import { generateObject } from "ai";
import { HTTPException } from "hono/http-exception";

const MAX_CONTEXT_SNIPPETS = 10;
const MAX_SNIPPET_CHARS = 6000;
const MAX_TOTAL_CONTEXT_CHARS = 20000;
const MAX_MESSAGES = 20;

const PlanMessageSchema = z.object({
  role: z.enum(["user", "assistant"]),
  content: z.string().min(1).max(8000),
});

const ContextSnippetSchema = z.object({
  path: z.string().min(1).max(512),
  content: z.string().min(1).max(MAX_SNIPPET_CHARS * 2),
});

const PlanChatBodySchema = z
  .object({
    teamSlugOrId: z.string().min(1),
    repoFullName: z.string().min(1).optional(),
    branch: z.string().min(1).optional(),
    messages: z.array(PlanMessageSchema).min(1).max(MAX_MESSAGES),
    contextSnippets: z
      .array(ContextSnippetSchema)
      .max(MAX_CONTEXT_SNIPPETS)
      .optional(),
  })
  .openapi("PlanChatBody");

const PlanTaskSchema = z.object({
  title: z.string().min(1).max(160),
  prompt: z.string().min(1).max(8000),
  rationale: z.string().min(1).max(8000).optional(),
  priority: z.enum(["high", "medium", "low"]).optional(),
});

const PlanChatResponseSchema = z
  .object({
    reply: z.string().min(1),
    tasks: z.array(PlanTaskSchema).default([]),
    followUpQuestions: z.array(z.string().min(1).max(400)).default([]),
    model: z.string().min(1),
  })
  .openapi("PlanChatResponse");

type PlanChatBody = z.infer<typeof PlanChatBodySchema>;
type PlanChatResponse = z.infer<typeof PlanChatResponseSchema>;

type SanitizedSnippet = {
  path: string;
  content: string;
};

const systemPrompt = [
  "You are cmux Plan Mode, an assistant that helps engineers understand a repository and break work into actionable coding tasks.",
  "Respond with clear Markdown that first summarizes key insights, then proposes next steps.",
  "When suggesting tasks, make them focused and ready to hand to an autonomous coding agent.",
  "Only suggest tasks when you have enough code or requirements context; otherwise ask clarifying follow-up questions.",
  "Keep explanations concise and avoid repeating earlier assistant messages unless the user requests a recap.",
].join("\n");

function trimSnippets(snippets: SanitizedSnippet[]): SanitizedSnippet[] {
  if (snippets.length === 0) {
    return snippets;
  }

  const trimmed: SanitizedSnippet[] = [];
  let totalChars = 0;

  for (const snippet of snippets) {
    if (totalChars >= MAX_TOTAL_CONTEXT_CHARS) {
      break;
    }

    const remaining = MAX_TOTAL_CONTEXT_CHARS - totalChars;
    const limit = Math.min(MAX_SNIPPET_CHARS, remaining);
    const content = snippet.content.slice(0, limit);
    trimmed.push({
      path: snippet.path,
      content,
    });
    totalChars += content.length;
  }

  return trimmed;
}

function buildContextSection(snippets: SanitizedSnippet[]): string | null {
  if (snippets.length === 0) {
    return null;
  }

  const lines = snippets.map((snippet) => {
    return [`[File] ${snippet.path}`, snippet.content].join("\n");
  });

  return ["Repository files:", ...lines].join("\n\n");
}

function buildConversation(messages: PlanChatBody["messages"]): string {
  return messages
    .map((message, index) => {
      const speaker = message.role === "user" ? "User" : "Assistant";
      return `${speaker} ${index + 1}:\n${message.content.trim()}`;
    })
    .join("\n\n");
}

async function resolveOpenAIKey({
  accessToken,
  teamSlugOrId,
}: {
  accessToken: string;
  teamSlugOrId: string;
}): Promise<string> {
  const convex = getConvex({ accessToken });
  const apiKeys = await convex.query(api.apiKeys.getAllForAgents, {
    teamSlugOrId,
  });
  const mergedKeys = mergeApiKeysWithEnv(apiKeys ?? {});
  const key = mergedKeys.OPENAI_API_KEY;

  if (!key) {
    throw new HTTPException(400, {
      message:
        "OpenAI API key is not configured. Add it in Settings to use Plan Mode.",
    });
  }

  return key;
}

async function runPlanModel({
  payload,
  apiKey,
}: {
  payload: PlanChatBody;
  apiKey: string;
}): Promise<PlanChatResponse> {
  const openai = createOpenAI({ apiKey });

  const sanitizedSnippets = trimSnippets(
    (payload.contextSnippets ?? []).map((snippet) => ({
      path: snippet.path,
      content: snippet.content,
    })),
  );

  const repoContext = payload.repoFullName
    ? `Repository: ${payload.repoFullName}${payload.branch ? `@${payload.branch}` : ""}`
    : null;
  const snippetSection = buildContextSection(sanitizedSnippets);
  const conversation = buildConversation(payload.messages);

  const promptParts = [
    repoContext,
    snippetSection,
    "Conversation so far:",
    conversation,
    "Respond to the most recent user message. Provide a Markdown reply and up to five sharply scoped task prompts ready for coding agents.",
  ].filter((part): part is string => Boolean(part));

  const { object } = await generateObject({
    model: openai("gpt-5-pro"),
    system: systemPrompt,
    prompt: promptParts.join("\n\n---\n\n"),
    schema: PlanChatResponseSchema,
    temperature: 0.2,
    maxRetries: 2,
  });

  return {
    ...object,
    model: "openai/gpt-5-pro",
  };
}

export const planRouter = new OpenAPIHono();

planRouter.openapi(
  createRoute({
    method: "post",
    path: "/plan/chat",
    tags: ["Plan"],
    summary: "Generate a planning response for Plan Mode",
    request: {
      body: {
        content: {
          "application/json": {
            schema: PlanChatBodySchema,
          },
        },
        required: true,
      },
    },
    responses: {
      200: {
        description: "Generated plan response",
        content: {
          "application/json": {
            schema: PlanChatResponseSchema,
          },
        },
      },
      400: { description: "Missing OpenAI credentials" },
      401: { description: "Unauthorized" },
      403: { description: "Forbidden" },
      500: { description: "Failed to generate plan" },
    },
  }),
  async (c) => {
    const body = c.req.valid("json");
    const accessToken = await getAccessTokenFromRequest(c.req.raw);
    if (!accessToken) {
      throw new HTTPException(401, { message: "Unauthorized" });
    }

    await verifyTeamAccess({
      req: c.req.raw,
      accessToken,
      teamSlugOrId: body.teamSlugOrId,
    });

    try {
      const apiKey = await resolveOpenAIKey({
        accessToken,
        teamSlugOrId: body.teamSlugOrId,
      });

      const response = await runPlanModel({
        payload: body,
        apiKey,
      });

      return c.json(response, 200);
    } catch (error) {
      if (error instanceof HTTPException) {
        throw error;
      }
      console.error("[PlanRoute] Failed to generate plan", error);
      throw new HTTPException(500, {
        message: "Failed to generate plan response",
      });
    }
  },
);
