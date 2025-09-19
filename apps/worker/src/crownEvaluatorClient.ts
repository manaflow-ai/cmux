import { createClient } from "@cmux/www-openapi-client/client";
import {
  postApiCrownEvaluate,
  postApiCrownSummarize,
} from "@cmux/www-openapi-client";
import { log } from "./logger.js";

interface CrownEvaluationOptions {
  prompt: string;
  teamSlugOrId: string;
  authToken: string;
  wwwBaseUrl: string;
}

interface CrownSummarizationOptions {
  prompt: string;
  teamSlugOrId?: string;
  authToken: string;
  wwwBaseUrl: string;
}

export async function evaluateCrownDirectly({
  prompt,
  teamSlugOrId,
  authToken,
  wwwBaseUrl,
}: CrownEvaluationOptions): Promise<{
  winner: number;
  reason: string;
} | null> {
  try {
    log("INFO", "[CrownEvaluatorClient] Starting crown evaluation", {
      teamSlugOrId,
      promptLength: prompt.length,
    });

    const client = createClient();
    const customFetch = (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      headers.set("x-stack-auth", authToken);
      return fetch(input, { ...init, headers });
    };
    client.setConfig({
      baseUrl: wwwBaseUrl,
      fetch: customFetch as typeof fetch,
    });

    const response = await postApiCrownEvaluate({
      client,
      body: {
        prompt,
        teamSlugOrId,
      },
    });

    if (!response.data) {
      log("ERROR", "[CrownEvaluatorClient] No data in crown evaluation response");
      return null;
    }

    log("INFO", "[CrownEvaluatorClient] Crown evaluation completed", {
      winner: response.data.winner,
      reason: response.data.reason,
    });

    return response.data;
  } catch (error) {
    log("ERROR", "[CrownEvaluatorClient] Crown evaluation failed", error);
    return null;
  }
}

export async function summarizeCrownDirectly({
  prompt,
  teamSlugOrId,
  authToken,
  wwwBaseUrl,
}: CrownSummarizationOptions): Promise<string | null> {
  try {
    log("INFO", "[CrownEvaluatorClient] Starting crown summarization", {
      teamSlugOrId,
      promptLength: prompt.length,
    });

    const client = createClient();
    const customFetch = (input: RequestInfo | URL, init?: RequestInit) => {
      const headers = new Headers(init?.headers);
      headers.set("x-stack-auth", authToken);
      return fetch(input, { ...init, headers });
    };
    client.setConfig({
      baseUrl: wwwBaseUrl,
      fetch: customFetch as typeof fetch,
    });

    const response = await postApiCrownSummarize({
      client,
      body: {
        prompt,
        teamSlugOrId,
      },
    });

    if (!response.data) {
      log("ERROR", "[CrownEvaluatorClient] No data in crown summarization response");
      return null;
    }

    log("INFO", "[CrownEvaluatorClient] Crown summarization completed", {
      summaryLength: response.data.summary.length,
    });

    return response.data.summary;
  } catch (error) {
    log("ERROR", "[CrownEvaluatorClient] Crown summarization failed", error);
    return null;
  }
}