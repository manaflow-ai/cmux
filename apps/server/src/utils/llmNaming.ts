import { serverLogger } from "./fileLogger.js";

interface NamingOptions {
  taskDescription: string;
  taskId: string;
  repoUrl?: string;
  apiKeys: Record<string, string>;
  branchPrefix?: string;
}

interface NamingResult {
  branchName: string;
  folderName: string;
}

interface LLMProvider {
  name: string;
  models: {
    cheap: string;
    fallback?: string;
  };
  checkAvailable: (apiKeys: Record<string, string>) => boolean;
  generateNames: (options: NamingOptions, model: string, apiKey: string) => Promise<NamingResult>;
}

const PROVIDERS: LLMProvider[] = [
  {
    name: "anthropic",
    models: {
      cheap: "claude-3-5-haiku-20241022",
      fallback: "claude-3-haiku-20240307"
    },
    checkAvailable: (apiKeys) => !!apiKeys.ANTHROPIC_API_KEY,
    generateNames: async (options, model, apiKey) => {
      const response = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-api-key": apiKey,
          "anthropic-version": "2023-06-01"
        },
        body: JSON.stringify({
          model,
          max_tokens: 100,
          messages: [{
            role: "user",
            content: `Generate a concise git branch name and folder name for this task. The names should be descriptive but short (max 30 chars each).

Task: ${options.taskDescription}

Respond ONLY with a JSON object in this exact format:
{"branch": "feature-name", "folder": "folder-name"}

Rules:
- Use only lowercase letters, numbers, and hyphens
- No spaces or special characters
- Be descriptive but concise
- Branch name should indicate the type of change`
          }]
        })
      });

      if (!response.ok) {
        throw new Error(`Anthropic API error: ${response.status}`);
      }

      const data = await response.json();
      const content = data.content[0].text;
      
      try {
        const parsed = JSON.parse(content);
        return {
          branchName: parsed.branch,
          folderName: parsed.folder
        };
      } catch (e) {
        throw new Error("Failed to parse LLM response");
      }
    }
  },
  {
    name: "openai",
    models: {
      cheap: "gpt-3.5-turbo",
      fallback: "gpt-4o-mini"
    },
    checkAvailable: (apiKeys) => !!apiKeys.OPENAI_API_KEY,
    generateNames: async (options, model, apiKey) => {
      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${apiKey}`
        },
        body: JSON.stringify({
          model,
          max_tokens: 100,
          messages: [{
            role: "user",
            content: `Generate a concise git branch name and folder name for this task. The names should be descriptive but short (max 30 chars each).

Task: ${options.taskDescription}

Respond ONLY with a JSON object in this exact format:
{"branch": "feature-name", "folder": "folder-name"}

Rules:
- Use only lowercase letters, numbers, and hyphens
- No spaces or special characters
- Be descriptive but concise
- Branch name should indicate the type of change`
          }],
          response_format: { type: "json_object" }
        })
      });

      if (!response.ok) {
        throw new Error(`OpenAI API error: ${response.status}`);
      }

      const data = await response.json();
      const content = data.choices[0].message.content;
      
      try {
        const parsed = JSON.parse(content);
        return {
          branchName: parsed.branch,
          folderName: parsed.folder
        };
      } catch (e) {
        throw new Error("Failed to parse LLM response");
      }
    }
  },
  {
    name: "gemini",
    models: {
      cheap: "gemini-2.0-flash-exp",
      fallback: "gemini-1.5-flash"
    },
    checkAvailable: (apiKeys) => !!apiKeys.GEMINI_API_KEY,
    generateNames: async (options, model, apiKey) => {
      const response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          contents: [{
            parts: [{
              text: `Generate a concise git branch name and folder name for this task. The names should be descriptive but short (max 30 chars each).

Task: ${options.taskDescription}

Respond ONLY with a JSON object in this exact format:
{"branch": "feature-name", "folder": "folder-name"}

Rules:
- Use only lowercase letters, numbers, and hyphens
- No spaces or special characters
- Be descriptive but concise
- Branch name should indicate the type of change`
            }]
          }],
          generationConfig: {
            temperature: 0.2,
            maxOutputTokens: 100,
            responseMimeType: "application/json"
          }
        })
      });

      if (!response.ok) {
        const errorText = await response.text();
        throw new Error(`Gemini API error: ${response.status} - ${errorText}`);
      }

      const data = await response.json();
      const content = data.candidates[0].content.parts[0].text;
      
      try {
        const parsed = JSON.parse(content);
        return {
          branchName: parsed.branch,
          folderName: parsed.folder
        };
      } catch (e) {
        throw new Error("Failed to parse LLM response");
      }
    }
  }
];

/**
 * Sanitize a name to ensure it's valid for git branches and file systems
 */
function sanitizeName(name: string, maxLength: number = 30): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/--+/g, "-")
    .replace(/^-|-$/g, "")
    .substring(0, maxLength);
}

/**
 * Generate a fallback name based on task description
 */
function generateFallbackNames(taskDescription: string, taskId: string): NamingResult {
  const words = taskDescription
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, "")
    .trim()
    .split(/\s+/)
    .slice(0, 5);
  
  const base = words.join("-").substring(0, 20);
  const timestamp = Date.now();
  
  return {
    branchName: `task-${base}-${timestamp}`,
    folderName: `cmux-${timestamp}`
  };
}

/**
 * Select the best available LLM provider based on API keys
 */
function selectProvider(apiKeys: Record<string, string>): LLMProvider | null {
  // Check environment variables as fallback
  const enrichedApiKeys = {
    ...apiKeys,
    ANTHROPIC_API_KEY: apiKeys.ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "",
    OPENAI_API_KEY: apiKeys.OPENAI_API_KEY || process.env.OPENAI_API_KEY || "",
    GEMINI_API_KEY: apiKeys.GEMINI_API_KEY || process.env.GEMINI_API_KEY || ""
  };

  // Priority order: Anthropic > OpenAI > Gemini
  for (const provider of PROVIDERS) {
    if (provider.checkAvailable(enrichedApiKeys)) {
      return provider;
    }
  }
  return null;
}

/**
 * Generate better folder and branch names using LLMs
 */
export async function generateLLMNames(options: NamingOptions): Promise<NamingResult> {
  serverLogger.info("[LLMNaming] Generating names for task");
  
  const provider = selectProvider(options.apiKeys);
  
  if (!provider) {
    serverLogger.warn("[LLMNaming] No LLM provider available, using fallback");
    return generateFallbackNames(options.taskDescription, options.taskId);
  }

  serverLogger.info(`[LLMNaming] Using ${provider.name} provider`);
  
  // Get API key from enriched sources (DB or env)
  const enrichedApiKeys = {
    ...options.apiKeys,
    ANTHROPIC_API_KEY: options.apiKeys.ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "",
    OPENAI_API_KEY: options.apiKeys.OPENAI_API_KEY || process.env.OPENAI_API_KEY || "",
    GEMINI_API_KEY: options.apiKeys.GEMINI_API_KEY || process.env.GEMINI_API_KEY || ""
  };
  
  const apiKey = enrichedApiKeys[
    provider.name === "anthropic" ? "ANTHROPIC_API_KEY" :
    provider.name === "openai" ? "OPENAI_API_KEY" :
    "GEMINI_API_KEY"
  ];

  try {
    // Try the cheap model first
    let result = await provider.generateNames(options, provider.models.cheap, apiKey);
    
    // Sanitize the results
    result = {
      branchName: sanitizeName(result.branchName),
      folderName: sanitizeName(result.folderName)
    };
    
    // Apply prefix if configured
    if (options.branchPrefix) {
      result.branchName = `${sanitizeName(options.branchPrefix)}-${result.branchName}`;
    }
    
    // Ensure uniqueness by appending taskId suffix if needed
    const taskIdSuffix = `-${options.taskId.slice(-8)}`;
    result.branchName = `${result.branchName}${taskIdSuffix}`;
    result.folderName = `${result.folderName}${taskIdSuffix}`;
    
    serverLogger.info(`[LLMNaming] Generated names - branch: ${result.branchName}, folder: ${result.folderName}`);
    
    return result;
  } catch (error) {
    serverLogger.error(`[LLMNaming] Error with ${provider.name}:`, error);
    
    // Try fallback model if available
    if (provider.models.fallback) {
      try {
        serverLogger.info(`[LLMNaming] Trying fallback model ${provider.models.fallback}`);
        let result = await provider.generateNames(options, provider.models.fallback, apiKey);
        
        result = {
          branchName: sanitizeName(result.branchName),
          folderName: sanitizeName(result.folderName)
        };
        
        if (options.branchPrefix) {
          result.branchName = `${sanitizeName(options.branchPrefix)}-${result.branchName}`;
        }
        
        const taskIdSuffix = `-${options.taskId.slice(-8)}`;
        result.branchName = `${result.branchName}${taskIdSuffix}`;
        result.folderName = `${result.folderName}${taskIdSuffix}`;
        
        return result;
      } catch (fallbackError) {
        serverLogger.error(`[LLMNaming] Fallback also failed:`, fallbackError);
      }
    }
    
    // Use fallback generation
    return generateFallbackNames(options.taskDescription, options.taskId);
  }
}

/**
 * Check if a branch already exists
 */
export async function checkBranchExists(
  repoPath: string,
  branchName: string
): Promise<boolean> {
  try {
    const { exec } = await import("child_process");
    const { promisify } = await import("util");
    const execAsync = promisify(exec);
    
    await execAsync(`git show-ref --verify --quiet refs/heads/${branchName}`, {
      cwd: repoPath
    });
    
    return true;
  } catch {
    return false;
  }
}

/**
 * Ensure branch name is unique by appending a counter if needed
 */
export async function ensureUniqueBranchName(
  repoPath: string,
  baseBranchName: string
): Promise<string> {
  let branchName = baseBranchName;
  let counter = 1;
  
  while (await checkBranchExists(repoPath, branchName)) {
    branchName = `${baseBranchName}-${counter}`;
    counter++;
  }
  
  return branchName;
}