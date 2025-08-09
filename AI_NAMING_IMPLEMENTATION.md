# AI-Powered Naming Implementation

## Overview

This implementation adds AI-powered naming for folders and branch names in the cmux task system. Instead of using generic timestamp-based names like `cmux-1234567890`, the system now generates descriptive names based on the task description using cheap AI models.

## Features

### 1. **AI Provider Detection**
- Automatically detects available AI providers (OpenAI, Anthropic, Gemini) based on stored API keys
- Priority order: OpenAI → Anthropic → Gemini (based on reliability and cost)
- Falls back to timestamp-based naming if no providers are available

### 2. **Cheap Model Usage**
- **OpenAI**: `gpt-4o-mini` (cheap and fast)
- **Anthropic**: `claude-3-5-haiku-20241022` (as requested)
- **Gemini**: `gemini-2.0-flash-exp` (flash variant for speed)

### 3. **Configurable Branch Prefixes**
- Added `branchPrefix` setting to workspace settings
- Default: empty string (no prefix)
- Can be configured per workspace
- Example: setting prefix to "feature/" results in names like "feature/implement-user-auth-123456"

### 4. **Smart Name Generation**
- Generates descriptive names (max 40 chars, lowercase, hyphenated)
- Ensures uniqueness by appending timestamp suffix
- Per-agent uniqueness: agent names are inserted intelligently to preserve readability
- Example: `implement-user-auth-claude-sonnet-4-123456`

### 5. **Fallback Mechanisms**
- If AI generation fails → timestamp-based naming
- If API keys not available → timestamp-based naming
- If task description too short → timestamp-based naming

## Files Modified/Created

### New Files
- `packages/shared/src/aiProviderDetector.ts` - Environment variable based detection (unused)
- `packages/shared/src/aiNamingService.ts` - Main AI naming service

### Modified Files
- `packages/convex/convex/schema.ts` - Added `branchPrefix` and `enableAINaming` to workspace settings
- `packages/convex/convex/workspaceSettings.ts` - Updated mutation to handle new fields
- `apps/server/src/workspace.ts` - Integrated AI naming into workspace creation
- `apps/server/src/agentSpawner.ts` - Updated to pass task description and handle agent-specific naming

## Configuration

The system can be configured via workspace settings:

```typescript
{
  enableAINaming: boolean, // Default: true (enabled)
  branchPrefix: string,    // Default: "" (no prefix)
  worktreePath: string     // Existing setting for custom workspace paths
}
```

## API Integration

The system retrieves API keys from Convex storage and uses them to call the appropriate AI providers:

1. Fetch API keys using `api.apiKeys.getAllForAgents`
2. Detect available providers from the key map
3. Choose the preferred provider (OpenAI > Anthropic > Gemini)
4. Generate names using the provider's cheap model
5. Clean and format the generated names
6. Ensure uniqueness and agent-specific naming

## Example Naming Flow

Given task: "Implement user authentication with JWT tokens"

### Without AI (fallback):
- Branch: `cmux-1704123456`
- Folder: `cmux-1704123456` 

### With AI (OpenAI available):
- Branch: `implement-user-auth-jwt-123456`
- Folder: `implement-user-auth-jwt-123456`

### With AI + Agent specific:
- Branch: `implement-user-auth-jwt-claude-sonnet-4-123456`
- Folder: `implement-user-auth-jwt-claude-sonnet-4-123456`

### With Prefix ("feature/"):
- Branch: `feature/implement-user-auth-jwt-123456`
- Folder: `feature/implement-user-auth-jwt-123456`

## Benefits

1. **Better Organization**: Meaningful names make it easier to identify task outputs
2. **Cost Effective**: Uses the cheapest available models (typically $0.0001-0.0005 per request)
3. **Backwards Compatible**: Falls back gracefully when AI is unavailable
4. **Configurable**: Users can enable/disable AI naming and set custom prefixes
5. **Unique per Agent**: Each agent gets its own uniquely named branch/folder
6. **Provider Agnostic**: Works with any of the three major AI providers

## Future Improvements

1. **Caching**: Cache generated names to avoid duplicate API calls for similar tasks
2. **Custom Prompts**: Allow users to customize the naming prompt
3. **Length Limits**: Make name length limits configurable
4. **More Providers**: Add support for additional AI providers (Cohere, etc.)
5. **Local Models**: Support for local/offline naming models