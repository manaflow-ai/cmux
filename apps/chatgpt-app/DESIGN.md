# ChatGPT cmux App Design

## Background
- Goal: allow a ChatGPT custom app to recognize `@cmux …` mentions and orchestrate a cmux task that boots multiple agents, an OpenVSCode window, and a live browser preview inside ChatGPT.
- ChatGPT custom apps use the Apps SDK. We need an MCP server for LLM↔cmux orchestration plus a custom iframe component that reads data via `window.openai` (per the "Build a custom UX" guide) and renders the remote IDE/preview.
- cmux already provisions Morph-backed sandboxes, launches OpenVSCode, exposes preview ports, and tracks artifacts via Convex. The app should reuse those primitives rather than re-implementing sandbox logic.

## Success Criteria
- A ChatGPT user can type `@cmux <task>` and the model reliably routes to our MCP tool.
- The tool returns structured data describing the created task, spawned run, VS Code endpoint, and preview endpoints. The custom iframe immediately renders both panes and negotiates fullscreen mode when helpful.
- The workflow respects existing team membership, honors iframe preflight checks, and surfaces errors with actionable guidance.

## High-Level Architecture
- **Manifest (`apps/chatgpt-app/app.json`)**
  - Declares the cmux MCP server endpoint, auth requirements, and tool schemas (at least `cmux.create_task` and `cmux.poll_task`).
  - Registers `customUi` → `web/dist/component.js` so the host renders our iframe bundle after tool calls.
- **Server (`apps/chatgpt-app/server/`)**
  - Node 24 + Bun runtime using `@modelcontextprotocol/sdk` (matches existing repo standards for Node imports).
  - Provides tools that call into internal cmux services (Convex mutations/queries and Hono routes) to:
    1. Create a task + spawn a run with the default agent ensemble.
    2. Fetch run state (networking info, agents, logs) as deterministic JSON.
    3. Resolve iframe-safe URLs via cmux-proxy / iframe-preflight utilities before returning to ChatGPT.
  - Emits `toolOutput` matching a Zod schema exposed in the manifest so the React component can render without runtime guessing.
- **Frontend Bundle (`apps/chatgpt-app/web/`)**
  - React 18 + TypeScript, bundled with esbuild into a single ESM file per Apps SDK guidance.
  - Uses `window.openai` helpers: reads `toolOutput`, stores UI selections in `setWidgetState`, switches between inline and fullscreen via `requestDisplayMode`, and can trigger follow-up tool calls (refresh status, spawn extra agents).
  - Renders two persistent iframes (VS Code + browser preview) using the same sandbox/allowlist attributes we rely on in `apps/client` (e.g., keyboard + clipboard permissions, `sandbox="allow-scripts allow-same-origin allow-forms"`).

## Data Flow
1. **Mention detection**
   - Model instruction in manifest encourages the assistant to call `cmux.create_task` whenever it encounters `@cmux <task text>`.
   - Tool input schema
     ```ts
     z.object({
       teamSlugOrId: z.string(),
       taskText: z.string(),
       repoFullName: z.string().optional(),
       environmentId: z.string().optional(),
       agentPreset: z.enum(["default", "stack", "llm-heavy"]).default("default"),
       openPreview: z.boolean().default(true)
     })
     ```
2. **Tool handler**
   - Validates the caller using cmux OAuth (Apps SDK auth doc) and resolves `teamSlugOrId` to a Convex team id.
   - Calls `api.tasks.create` then `api.taskRuns.create` (with our default agent list) via backend service helpers. The run id is returned.
   - Waits for `agentSpawner` to emit VSCode + preview metadata via existing server sockets or polls `taskRuns.getWithNetworking` using Convex queries until `networking` entries exist.
   - For each URL:
     - Normalize Morph domains to `cmux.sh` (reuse `rewriteMorphUrl`).
     - Hit `iframe-preflight` Hono route with `required: true` content-type to confirm embed readiness and resume paused sandboxes if needed.
   - Persists context in storage (e.g., minted short-lived task access JWT) so follow-up refresh calls can reuse credentials.
   - Responds with structured payload:
     ```json
     {
       "type": "cmux_workspace",
       "task": { "id": "…", "url": "https://app.cmux.sh/..." },
       "run": { "id": "…", "agents": [ … ] },
       "workspace": {
         "vscode": { "url": "https://port-…cmux.sh/?folder=/root/workspace", "preflightStatus": "ready" },
         "preview": [
           { "port": 3000, "url": "https://port-3000-…cmux.sh", "label": "Vite" }
         ]
       },
       "pollToken": "JWT for cmux.poll_task",
       "message": "Workspace ready. Agents running…"
     }
     ```
3. **Custom component render**
   - `window.openai.toolOutput` provides the payload. Component stores it in local state + `setWidgetState` for persistence.
   - Requests `fullscreen` display mode when both panes need space; falls back to inline with collapsible layout for smaller results.
   - Embeds VS Code + preview iframes with persistent keys so reloads keep them alive.
   - Displays agent statuses/log tail using `callTool("cmux.poll_task", { pollToken })` on interval to surface progress in-app without forcing the model to narrate.

## Authentication & Security Considerations
- Use Apps SDK OAuth helpers to initiate a cmux login from ChatGPT. Server validates the resulting bearer token against cmux `stackServerAppJs` (same flow as Hono routes). Store encrypted refresh token in the `widgetState`? No—keep secrets server-side; only pass opaque `pollToken` JWT back to UI.
- All tool responses must scrub secrets. Only send iframe URLs already sanitized by `rewriteMorphUrl` and preflight checks.
- Ensure CORS + CSP headers from cmux services allow embedding in ChatGPT. Our cmux-proxy already strips `x-frame-options`; reuse it by returning proxied URLs when necessary.

## Frontend Component Notes
- Layout: split view with resizable divider (keyboard accessible). Cache the split ratio in `widgetState` so reopening the conversation restores layout.
- Provide quick actions:
  1. "Open in new tab" for VS Code and each preview (uses `window.openai.sendFollowupMessage` to post the link for the user and model awareness).
  2. "Refresh preview" uses `callTool("cmux.refresh_networking", …)` to trigger container restart or reload.
  3. Status pill summarizing active agents + last heartbeat.
- Handle loading phases surfaced by preflight (`resuming`, `resume_failed`, etc.) with friendly messaging before the iframe loads.
- Support dark mode automatically by mirroring `window.openai.theme` (values: `"light" | "dark" | "system"`).

## Implementation Phases (Incremental)
1. **Scaffold**
   - Add `apps/chatgpt-app/app.json`, `package.json` files for server/web, tsconfigs, and shared zod schemas under `apps/chatgpt-app/shared/`.
   - Implement Bun scripts: `bun run dev:server`, `bun run dev:web`, `bun run build:web` (esbuild bundling per SDK docs).
2. **Server MVP**
   - Implement auth handshake + `cmux.create_task` tool that calls Convex/Hono; return placeholder URLs for now.
   - Add vitest coverage for tool handlers (mock Convex + preflight responses).
3. **Workspace plumbing**
   - Wire up real sandbox spawn (call `sandboxesRouter` start endpoint, reuse `agentSpawner` utilities) and polling logic that follows existing `apps/server/src/socket-handlers.ts` patterns.
   - Issue short-lived JWT (existing `taskRuns.createTaskToken`) so follow-up polling doesn’t require re-auth.
4. **Custom UI**
   - Build React component with `window.openai` hooks and iframe shell; integrate status polling via `callTool`.
   - Bundle and test inside ChatGPT sandbox (use `window.openai.requestDisplayMode`).
5. **Polish**
   - Add error handling (failed spawn, sandbox paused, auth expiry), support multiple preview services, and allow users to switch between agent runs.
   - Document environment variables + runbook in `apps/chatgpt-app/README.md` once implementation stabilizes (per repo rules).

## Open Questions
- Do we support selecting a team interactively or infer the default from OAuth? (Likely fetch teams on login and store the user’s default in widget state.)
- Should the ChatGPT app trigger cmux notifications (Slack, email) when a workspace is spawned? Consider optional hook.
- How do we reconcile multiple concurrent `@cmux` tasks in a single conversation? The design assumes one active `pollToken` per widget; we may need tabbed UI later.
- Are there rate limits for Morph sandbox resumes that the app must respect? Might need exponential backoff inside polling.

## Repository Layout Stub
```
apps/chatgpt-app/
  DESIGN.md                 # This document
  app.json                  # Manifest (to be implemented)
  server/
    package.json            # Bun/Node server deps (future)
    src/
      index.ts              # MCP server entry (future)
  web/
    package.json            # React bundle deps (future)
    tsconfig.json
    src/
      component.tsx         # Custom iframe component (future)
    dist/
      component.js          # Built artifact consumed by app.json
  shared/
    schemas.ts              # Zod schemas shared by server + UI (future)
```
