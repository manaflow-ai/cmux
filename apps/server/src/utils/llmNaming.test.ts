import { describe, it, expect, vi } from "vitest";
import { generateLLMNames, ensureUniqueBranchName, checkBranchExists } from "./llmNaming.js";

// Mock the fetch function
global.fetch = vi.fn();

describe("llmNaming", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe("generateLLMNames", () => {
    it("should use fallback when no API keys are available", async () => {
      const result = await generateLLMNames({
        taskDescription: "Add user authentication feature",
        taskId: "task123",
        apiKeys: {},
      });

      expect(result.branchName).toMatch(/^task-add-user-authentication-feature-/);
      expect(result.folderName).toMatch(/^cmux-\d+$/);
    });

    it("should use Anthropic when API key is available", async () => {
      const mockFetch = vi.mocked(fetch);
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          content: [{
            text: '{"branch": "add-auth-feature", "folder": "auth-implementation"}'
          }]
        })
      } as Response);

      const result = await generateLLMNames({
        taskDescription: "Add user authentication feature",
        taskId: "task123",
        apiKeys: { ANTHROPIC_API_KEY: "test-key" },
      });

      expect(mockFetch).toHaveBeenCalledWith(
        "https://api.anthropic.com/v1/messages",
        expect.objectContaining({
          method: "POST",
          headers: expect.objectContaining({
            "x-api-key": "test-key",
          }),
        })
      );

      expect(result.branchName).toBe("add-auth-feature-task123");
      expect(result.folderName).toBe("auth-implementation-task123");
    });

    it("should apply branch prefix when configured", async () => {
      const mockFetch = vi.mocked(fetch);
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          content: [{
            text: '{"branch": "add-auth", "folder": "auth"}'
          }]
        })
      } as Response);

      const result = await generateLLMNames({
        taskDescription: "Add user authentication",
        taskId: "task123",
        apiKeys: { ANTHROPIC_API_KEY: "test-key" },
        branchPrefix: "feature"
      });

      expect(result.branchName).toBe("feature-add-auth-task123");
    });

    it("should prioritize Anthropic over OpenAI", async () => {
      const mockFetch = vi.mocked(fetch);
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          content: [{
            text: '{"branch": "test-branch", "folder": "test-folder"}'
          }]
        })
      } as Response);

      await generateLLMNames({
        taskDescription: "Test task",
        taskId: "task123",
        apiKeys: { 
          ANTHROPIC_API_KEY: "anthropic-key",
          OPENAI_API_KEY: "openai-key"
        },
      });

      expect(mockFetch).toHaveBeenCalledWith(
        "https://api.anthropic.com/v1/messages",
        expect.any(Object)
      );
    });

    it("should use environment variables as fallback", async () => {
      process.env.GEMINI_API_KEY = "env-gemini-key";
      
      const mockFetch = vi.mocked(fetch);
      mockFetch.mockResolvedValueOnce({
        ok: true,
        json: async () => ({
          candidates: [{
            content: {
              parts: [{
                text: '{"branch": "env-branch", "folder": "env-folder"}'
              }]
            }
          }]
        })
      } as Response);

      const result = await generateLLMNames({
        taskDescription: "Test with env vars",
        taskId: "task123",
        apiKeys: {}, // No API keys in database
      });

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining("generativelanguage.googleapis.com"),
        expect.any(Object)
      );

      expect(result.branchName).toBe("env-branch-task123");
      
      delete process.env.GEMINI_API_KEY;
    });
  });

  describe("ensureUniqueBranchName", () => {
    it("should return original name if it doesn't exist", async () => {
      const mockExec = vi.fn().mockRejectedValue(new Error("Branch not found"));
      vi.doMock("child_process", () => ({ exec: mockExec }));

      const result = await ensureUniqueBranchName("/repo/path", "feature-branch");
      expect(result).toBe("feature-branch");
    });

    it("should append counter if branch exists", async () => {
      const mockExec = vi.fn()
        .mockResolvedValueOnce({}) // First call - branch exists
        .mockRejectedValueOnce(new Error("Branch not found")); // Second call - branch doesn't exist
        
      vi.doMock("child_process", () => ({ exec: mockExec }));

      const result = await ensureUniqueBranchName("/repo/path", "feature-branch");
      expect(result).toBe("feature-branch-1");
    });
  });
});