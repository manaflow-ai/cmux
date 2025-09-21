import { describe, expect, it, vi, beforeEach } from "vitest";
import { generateObject, type GenerateObjectResult } from "ai";
import {
  toKebabCase,
  generateRandomId,
  generateBranchName,
  generatePRInfo,
  generatePRTitle,
  generateBranchBaseName,
  generateUniqueBranchNamesFromTitle,
  generateNewBranchName,
  generateUniqueBranchNames,
  getPRTitleFromTaskDescription,
  type PRGeneration,
} from "./branchNameGenerator.js";

vi.mock("ai", () => ({
  generateObject: vi.fn(),
}));

vi.mock("../utils/convexClient.js", () => {
  const mockClient = {
    query: vi.fn(),
    mutation: vi.fn(),
  };
  return {
    getConvex: () => mockClient,
    __mockClient: mockClient,
  };
});

vi.mock("./fileLogger.js", () => ({
  serverLogger: {
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  },
}));

// Helper function to create a mock GenerateObjectResult
function createMockGenerateObjectResult(object: PRGeneration): Partial<GenerateObjectResult<PRGeneration>> {
  return {
    object,
    finishReason: "stop",
    usage: {
      inputTokens: 100,
      outputTokens: 50,
      totalTokens: 150,
    },
  };
}

describe("branchNameGenerator", () => {
  describe("toKebabCase", () => {
    it("should convert camelCase to kebab-case", () => {
      expect(toKebabCase("camelCaseString")).toBe("camel-case-string");
    });

    it("should convert PascalCase to kebab-case", () => {
      expect(toKebabCase("PascalCaseString")).toBe("pascal-case-string");
    });

    it("should handle spaces and special characters", () => {
      expect(toKebabCase("Hello World! 123")).toBe("hello-world-123");
    });

    it("should handle multiple consecutive spaces", () => {
      expect(toKebabCase("hello    world")).toBe("hello-world");
    });

    it("should handle leading and trailing spaces", () => {
      expect(toKebabCase("  hello world  ")).toBe("hello-world");
    });

    it("should handle acronyms with pluralization", () => {
      expect(toKebabCase("PRs")).toBe("prs");
      expect(toKebabCase("APIs")).toBe("apis");
      expect(toKebabCase("IDs")).toBe("ids");
    });

    it("should handle mixed acronyms", () => {
      expect(toKebabCase("HTTPServer")).toBe("http-server");
      expect(toKebabCase("XMLHttpRequest")).toBe("xml-http-request");
    });

    it("should limit length to 50 characters", () => {
      const longString = "a".repeat(60);
      expect(toKebabCase(longString).length).toBeLessThanOrEqual(50);
    });

    it("should handle double hyphens correctly", () => {
      expect(toKebabCase("test--double")).toBe("test-double");
      expect(toKebabCase("multiple---hyphens")).toBe("multiple-hyphens");
      expect(toKebabCase("end-with-hyphen-")).toBe("end-with-hyphen");
      expect(toKebabCase("-start-with-hyphen")).toBe("start-with-hyphen");
    });

    it("should handle the specific case from the example", () => {
      const input = "add-llm-driven-auto-commit-and-push-for-completed-";
      const result = toKebabCase(input);
      expect(result).not.toContain("--");
      expect(result).toBe("add-llm-driven-auto-commit-and-push-for-completed");
    });
  });

  describe("generateRandomId", () => {
    it("should generate a 5-character string", () => {
      const id = generateRandomId();
      expect(id).toHaveLength(5);
    });

    it("should only contain lowercase letters and numbers", () => {
      const id = generateRandomId();
      expect(id).toMatch(/^[a-z0-9]{5}$/);
    });

    it("should generate different IDs", () => {
      const ids = new Set();
      for (let i = 0; i < 100; i++) {
        ids.add(generateRandomId());
      }
      expect(ids.size).toBeGreaterThan(90);
    });
  });

  describe("generateBranchName", () => {
    it("should generate a branch name that infers type and scope", () => {
      const branchName = generateBranchName("Fix authentication bug");
      expect(branchName).toBe(
        "chore/fix-authentication/fix-authentication-bug"
      );
    });

    it("should handle empty input", () => {
      const branchName = generateBranchName("");
      expect(branchName).toBe("chore/general/update");
    });

    it("should parse PR-style titles with type, scope, and issue", () => {
      const branchName = generateBranchName(
        "feat(auth): renew refresh tokens (#8810)"
      );
      expect(branchName).toBe("feat/auth/renew-refresh-tokens-8810");
    });

    it("should avoid double hyphens when trailing hyphen is present", () => {
      const branchName = generateBranchName("fix-bug-");
      expect(branchName).toBe("chore/fix-bug/fix-bug");
    });
  });

  describe("generatePRInfo", () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it("should generate PR info using OpenAI when API key is available", async () => {
      const mockObject = {
        branchName: "fix/auth/renew-refresh-tokens-8810",
        prTitle: "fix(auth): renew refresh tokens (#8810)",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const apiKeys = { OPENAI_API_KEY: "test-key" };
      const result = await generatePRInfo("Fix the authentication bug", apiKeys);

      expect(result).toEqual(mockObject);
      expect(generateObject).toHaveBeenCalledWith(
        expect.objectContaining({
          system: expect.stringContaining("git branch names and PR titles"),
          prompt: "Task: Fix the authentication bug",
          maxRetries: 2,
          temperature: 0.3,
        })
      );
    });

    it("should use Gemini when only GEMINI_API_KEY is available", async () => {
      const mockObject = {
        branchName: "feat/profile/add-user-profiles",
        prTitle: "feat(profile): add user profiles",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const apiKeys = { GEMINI_API_KEY: "test-key" };
      const result = await generatePRInfo("Add user profile", apiKeys);

      expect(result).toEqual(mockObject);
    });

    it("should use Anthropic when only ANTHROPIC_API_KEY is available", async () => {
      const mockObject = {
        branchName: "chore/infra/update-dependencies",
        prTitle: "chore(infra): update dependencies",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const apiKeys = { ANTHROPIC_API_KEY: "test-key" };
      const result = await generatePRInfo("Update dependencies", apiKeys);

      expect(result).toEqual(mockObject);
    });

    it("should normalize generated output into the expected format", async () => {
      const mockObject = {
        branchName: "cmux/fix-auth/renew-refresh-tokens-8810",
        prTitle: "  fix(auth): renew refresh tokens (#8810)  ",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(
        mockResponse as GenerateObjectResult<PRGeneration>
      );

      const apiKeys = { OPENAI_API_KEY: "test-key" };
      const result = await generatePRInfo("Fix the authentication bug", apiKeys);

      expect(result).toEqual({
        branchName: "fix/auth/renew-refresh-tokens-8810",
        prTitle: "fix(auth): renew refresh tokens (#8810)",
      });
    });

    it("should return fallback when no API keys are available", async () => {
      const apiKeys = {};
      const result = await generatePRInfo("Fix the bug in authentication", apiKeys);

      expect(result).toEqual({
        branchName: "chore/fix-the/fix-the-bug-in-authentication",
        prTitle: "chore(fix-the): Fix the bug in authentication",
      });
      expect(generateObject).not.toHaveBeenCalled();
    });

    it("should handle API errors and return fallback", async () => {
      vi.mocked(generateObject).mockRejectedValueOnce(new Error("API Error"));

      const apiKeys = { OPENAI_API_KEY: "test-key" };
      const result = await generatePRInfo("Fix the bug", apiKeys);

      expect(result).toEqual({
        branchName: "chore/fix-the/fix-the-bug",
        prTitle: "chore(fix-the): Fix the bug",
      });
    });

    it("should prioritize OpenAI over Gemini", async () => {
      const mockObject = {
        branchName: "test-branch",
        prTitle: "Test PR Title",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const apiKeys = { 
        OPENAI_API_KEY: "openai-key",
        GEMINI_API_KEY: "gemini-key",
        ANTHROPIC_API_KEY: "anthropic-key",
      };
      await generatePRInfo("Test task", apiKeys);

      expect(generateObject).toHaveBeenCalledWith(
        expect.objectContaining({
          model: expect.objectContaining({
            modelId: "gpt-5-nano",
          }),
        })
      );
    });
  });

  describe("generatePRTitle", () => {
    it("should return only the PR title from generatePRInfo", async () => {
      const mockObject = {
        branchName: "fix-bug",
        prTitle: "Fix critical bug",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const apiKeys = { OPENAI_API_KEY: "test-key" };
      const title = await generatePRTitle("Fix bug", apiKeys);

      expect(title).toBe("Fix critical bug");
    });

    it("should return null when generatePRInfo returns null", async () => {
      const apiKeys = {};
      const title = await generatePRTitle("", apiKeys);

      expect(title).toBe("chore(general): update task");
    });
  });

  describe("generateUniqueBranchNamesFromTitle", () => {
    it("should generate the requested number of unique branch names", () => {
      const branches = generateUniqueBranchNamesFromTitle("Fix Bug", 5);

      expect(branches).toHaveLength(5);
      expect(new Set(branches).size).toBe(5);

      branches.forEach(branch => {
        expect(branch).toMatch(/^chore\/fix-bug\/fix-bug-[a-z0-9]{5}$/);
      });
    });

    it("should handle empty title", () => {
      const branches = generateUniqueBranchNamesFromTitle("", 3);

      expect(branches).toHaveLength(3);
      branches.forEach(branch => {
        expect(branch).toMatch(/^chore\/general\/update-[a-z0-9]{5}$/);
      });
    });

    it("should not create double hyphens with trailing hyphen titles", () => {
      const branches = generateUniqueBranchNamesFromTitle("fix-bug-", 3);

      expect(branches).toHaveLength(3);
      branches.forEach(branch => {
        expect(branch).not.toContain("--");
        expect(branch).toMatch(/^chore\/fix-bug\/fix-bug-[a-z0-9]{5}$/);
      });
    });
  });

  describe("generateBranchBaseName", () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    it("should generate base name from API response", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({
        OPENAI_API_KEY: "test-key"
      });

      const mockObject = {
        branchName: "feat/app/add-feature",
        prTitle: "feat(app): add new feature",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const baseName = await generateBranchBaseName(
        "Add new feature to the app",
        "default"
      );
      expect(baseName).toBe("feat/app/add-feature");
    });

    it("should use fallback when API fails", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({});

      const baseName = await generateBranchBaseName(
        "Test task description here",
        "default"
      );
      expect(baseName).toBe(
        "chore/test-task/test-task-description-here"
      );
    });
  });

  describe("generateNewBranchName", () => {
    it("should generate branch name with provided ID", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({});

      const branchName = await generateNewBranchName(
        "Fix bug",
        "default",
        "abc12"
      );
      expect(branchName).toBe("chore/fix-bug/fix-bug-abc12");
    });

    it("should generate branch name with random ID when not provided", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({});

      const branchName = await generateNewBranchName("Fix bug", "default");
      expect(branchName).toMatch(/^chore\/fix-bug\/fix-bug-[a-z0-9]{5}$/);
    });
  });

  describe("generateUniqueBranchNames", () => {
    it("should generate multiple unique branch names", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({});

      const branches = await generateUniqueBranchNames(
        "Add feature",
        3,
        "default"
      );

      expect(branches).toHaveLength(3);
      expect(new Set(branches).size).toBe(3);

      branches.forEach(branch => {
        expect(branch).toMatch(/^chore\/add-feature\/add-feature-[a-z0-9]{5}$/);
      });
    });
  });

  describe("getPRTitleFromTaskDescription", () => {
    it("should return PR title from API", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({ 
        OPENAI_API_KEY: "test-key" 
      });

      const mockObject = {
        branchName: "fix-bug",
        prTitle: "Fix authentication bug",
      };
      const mockResponse = createMockGenerateObjectResult(mockObject);
      vi.mocked(generateObject).mockResolvedValueOnce(mockResponse as GenerateObjectResult<PRGeneration>);

      const title = await getPRTitleFromTaskDescription(
        "Fix the authentication bug",
        "default"
      );
      expect(title).toBe("Fix authentication bug");
    });

    it("should return fallback title when API unavailable", async () => {
      const mockConvex = await import("../utils/convexClient.js");
      vi.mocked((mockConvex as any).__mockClient.query).mockResolvedValueOnce({});

      const title = await getPRTitleFromTaskDescription(
        "This is a long task description that should be truncated",
        "default"
      );
      expect(title).toBe(
        "chore(this-is): This is a long task description that should"
      );
    });
  });

  describe("branchNameGenerator format validation", () => {
    it("generateRandomId returns 5 alphanumerics", () => {
      const id = generateRandomId();
      expect(id).toMatch(/^[a-z0-9]{5}$/);
    });

    it("generateBranchName produces normalized format", () => {
      const name = generateBranchName("Implement cool feature!");
      expect(name).toBe(
        "chore/implement-cool/implement-cool-feature"
      );
      expect(name).toMatch(
        /^(feat|fix|chore|refactor|docs|test|perf|build|ci|revert|spike)\/[a-z0-9-]+\/[a-z0-9-]+$/
      );
    });

    it("generateUniqueBranchNamesFromTitle produces unique names with 5-digit suffix", () => {
      const count = 10;
      const names = generateUniqueBranchNamesFromTitle("Add feature", count);
      expect(names).toHaveLength(count);
      const set = new Set(names);
      expect(set.size).toBe(count);
      for (const n of names) {
        expect(n.startsWith("chore/add-feature/add-feature-")).toBe(true);
        expect(n).toMatch(/-[a-z0-9]{5}$/);
      }
    });
  });
});
