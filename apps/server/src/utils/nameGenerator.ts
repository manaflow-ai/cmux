import crypto from "crypto";

interface ProviderInfo {
  provider: "openai" | "anthropic" | "gemini";
  model: string;
  apiKey: string;
}

/**
 * Attempt to detect which LLM provider the user has credentials for.
 * The preference order is OpenAI -> Anthropic -> Gemini.
 */
function detectProvider(): ProviderInfo | undefined {
  if (process.env.OPENAI_API_KEY) {
    return {
      provider: "openai",
      model: "gpt-5-nano",
      apiKey: process.env.OPENAI_API_KEY,
    };
  }
  if (process.env.ANTHROPIC_API_KEY) {
    return {
      provider: "anthropic",
      model: "claude-3-5-haiku-20241022",
      apiKey: process.env.ANTHROPIC_API_KEY,
    };
  }
  if (process.env.GEMINI_API_KEY) {
    return {
      provider: "gemini",
      model: "gemini-2.5-flash-lite",
      apiKey: process.env.GEMINI_API_KEY,
    };
  }
  return undefined;
}

/** Very small helper to convert an arbitrary string into a Git-safe slug */
function slugify(text: string): string {
  return text
    .toLowerCase()
    // replace spaces and underscores with dash
    .replace(/[\s_]+/g, "-")
    // remove invalid characters
    .replace(/[^a-z0-9\-\/]/g, "")
    // collapse multiple dashes
    .replace(/-+/g, "-")
    // trim leading/trailing dashes
    .replace(/^-+|-+$/g, "");
}

async function callProvider({ provider, model, apiKey }: ProviderInfo, prompt: string): Promise<string | undefined> {
  try {
    switch (provider) {
      case "openai": {
        const response = await fetch("https://api.openai.com/v1/chat/completions", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${apiKey}`,
          },
          body: JSON.stringify({
            model,
            messages: [{ role: "user", content: prompt }],
            temperature: 0.7,
            max_tokens: 16,
          }),
        });
        const json: any = await response.json();
        return json?.choices?.[0]?.message?.content?.trim();
      }
      case "anthropic": {
        const response = await fetch("https://api.anthropic.com/v1/messages", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
          },
          body: JSON.stringify({
            model,
            temperature: 0.7,
            max_tokens: 16,
            messages: [{ role: "user", content: prompt }],
          }),
        });
        const json: any = await response.json();
        // The completion text is in json.content[0].text according to Anthropic API
        if (Array.isArray(json?.content) && json.content.length > 0) {
          return (json.content[0].text as string).trim();
        }
        return undefined;
      }
      case "gemini": {
        const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
        const response = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            contents: [
              {
                parts: [{ text: prompt }],
              },
            ],
            generationConfig: {
              candidateCount: 1,
              maxOutputTokens: 16,
              temperature: 0.7,
            },
          }),
        });
        const json: any = await response.json();
        if (Array.isArray(json?.candidates) && json.candidates.length > 0) {
          return json.candidates[0].content?.parts?.[0]?.text?.trim();
        }
        return undefined;
      }
    }
  } catch (error) {
    // Ignore and fall back to local generation
    console.warn("[nameGenerator] provider call failed", error);
  }
  return undefined;
}

export interface GenerateBranchNameOptions {
  /**
   * A short textual description of the task. The model will use this to produce a meaningful name.
   */
  taskDescription?: string;
  /** Optional prefix for the branch name */
  prefix?: string;
}

/**
 * Generate a Git-safe branch (and folder) name. It tries to invoke a cheap model if API
 * keys are available. If that fails, it falls back to a purely local slug.
 */
export async function generateBranchName({ taskDescription = "", prefix }: GenerateBranchNameOptions = {}): Promise<string> {
  const providerInfo = detectProvider();
  const prompt = taskDescription
    ? `Generate a short, hyphen-separated Git branch name (3-5 words, lowercase) describing the following task. Output ONLY the branch name.\nTask: ${taskDescription}`
    : "Generate a short, hyphen-separated, generic Git branch name. Output ONLY the branch name.";

  let base: string | undefined;
  if (providerInfo) {
    base = await callProvider(providerInfo, prompt);
  }

  if (!base) {
    // Fallback – use first five words of description or a random string
    if (taskDescription) {
      base = taskDescription
        .split(/\s+/)
        .slice(0, 5)
        .join("-");
    } else {
      base = "task";
    }
  }

  base = slugify(base);
  if (!base) base = "task";

  // Ensure uniqueness by appending a short timestamp hash
  const unique = crypto.randomBytes(3).toString("hex");

  const prefixEffective = prefix ?? process.env.BRANCH_PREFIX ?? "";
  const parts = [] as string[];
  if (prefixEffective) parts.push(slugify(prefixEffective));
  parts.push(base);
  parts.push(unique);

  return parts.filter(Boolean).join("-");
}