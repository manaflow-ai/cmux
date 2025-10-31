import {
  StrictMode,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";
import { createRoot } from "react-dom/client";

import {
  CmuxWorkspaceResultSchema,
  PollTaskResultSchema,
  type CmuxWorkspaceResult,
} from "../../shared/schemas";

type DisplayMode = "inline" | "fullscreen" | "pip";

type OpenAiDisplayModeEvent = {
  mode: DisplayMode;
};

type CallToolResult = {
  structuredContent?: unknown;
};

type OpenAiHostApi = {
  toolOutput?: unknown;
  widgetState?: unknown;
  setWidgetState?: (state: unknown) => void;
  requestDisplayMode?: (event: OpenAiDisplayModeEvent) => Promise<void>;
  callTool?: (name: string, args: Record<string, unknown>) => Promise<CallToolResult>;
};

declare global {
  interface Window {
    openai?: OpenAiHostApi;
  }
}

function parseWorkspace(value: unknown): CmuxWorkspaceResult | null {
  if (value === undefined || value === null) {
    return null;
  }
  const parsed = CmuxWorkspaceResultSchema.safeParse(value);
  if (!parsed.success) {
    console.warn("cmux-app: failed to parse workspace result", parsed.error);
    return null;
  }
  return parsed.data;
}

type WorkspaceSetter = (
  updater:
    | CmuxWorkspaceResult
    | ((prev: CmuxWorkspaceResult | null) => CmuxWorkspaceResult | null),
) => void;

function useCmuxWorkspace(): [CmuxWorkspaceResult | null, WorkspaceSetter] {
  const [workspace, setWorkspace] = useState<CmuxWorkspaceResult | null>(() =>
    parseWorkspace(window.openai?.toolOutput ?? window.openai?.widgetState),
  );

  const setAndPersist = useMemo<WorkspaceSetter>(() => {
    return (updater) => {
      setWorkspace((prev) => {
        const next =
          typeof updater === "function"
            ? updater(prev)
            : updater;
        if (next) {
          try {
            window.openai?.setWidgetState?.(next);
          } catch (error) {
            console.warn("cmux-app: failed to persist widget state", error);
          }
        }
        return next;
      });
    };
  }, []);

  useEffect(() => {
    const parsed = parseWorkspace(window.openai?.toolOutput);
    if (parsed !== null) {
      setWorkspace(parsed);
    }
  }, []);

  return [workspace, setAndPersist];
}

function useWorkspacePolling(
  workspace: CmuxWorkspaceResult | null,
  setWorkspace: WorkspaceSetter,
) {
  useEffect(() => {
    if (!workspace?.pollToken) {
      return;
    }
    const poll = async () => {
      try {
        const result = await window.openai?.callTool?.("cmux.poll_task", {
          pollToken: workspace.pollToken,
        });
        if (!result?.structuredContent) {
          return;
        }
        const parsed = PollTaskResultSchema.safeParse(result.structuredContent);
        if (!parsed.success) {
          console.warn(
            "cmux-app: failed to parse poll result",
            parsed.error.format(),
          );
          return;
        }
        setWorkspace((prev) => {
          if (!prev) {
            return prev;
          }
          const merged: CmuxWorkspaceResult = {
            ...prev,
            run: parsed.data.run,
            workspace: parsed.data.workspace,
            message: parsed.data.message ?? prev.message,
          };
          return merged;
        });
      } catch (error) {
        console.warn("cmux-app: poll failed", error);
      }
    };

    poll().catch(() => {
      /* handled above */
    });
    const interval = window.setInterval(poll, 12_000);
    return () => window.clearInterval(interval);
  }, [setWorkspace, workspace?.pollToken]);
}

function WorkspaceIframes({ workspace }: { workspace: CmuxWorkspaceResult }) {
  const { vscode, previews } = workspace.workspace;
  const [selectedPreview, setSelectedPreview] = useState(0);

  const effectivePreview = useMemo(() => {
    if (!previews.length) return null;
    const index = Math.min(Math.max(selectedPreview, 0), previews.length - 1);
    return previews[index];
  }, [previews, selectedPreview]);

  return (
    <div className="cmux-app__grid">
      <section className="cmux-app__panel">
        <header className="cmux-app__panel-header">
          <h2>VS Code</h2>
          <div className="cmux-app__panel-actions">
            <a
              href={vscode.url}
              target="_blank"
              rel="noreferrer noopener"
              className="cmux-app__link"
            >
              Open in new tab
            </a>
          </div>
        </header>
        <iframe
          src={vscode.url}
          title="cmux vscode iframe"
          allow="clipboard-read; clipboard-write; fullscreen"
          sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
        />
      </section>
      <section className="cmux-app__panel">
        <header className="cmux-app__panel-header">
          <h2>Browser Preview</h2>
          <div className="cmux-app__panel-actions">
            {effectivePreview ? (
              <a
                href={effectivePreview.url}
                target="_blank"
                rel="noreferrer noopener"
                className="cmux-app__link"
              >
                Open in new tab
              </a>
            ) : null}
          </div>
        </header>
        {previews.length === 0 ? (
          <div className="cmux-app__empty">No preview URLs yet.</div>
        ) : (
          <>
            {previews.length > 1 ? (
              <div className="cmux-app__preview-tabs">
                {previews.map((preview, index) => (
                  <button
                    key={preview.url}
                    type="button"
                    onClick={() => setSelectedPreview(index)}
                    className={
                      index === selectedPreview
                        ? "cmux-app__preview-tab cmux-app__preview-tab--active"
                        : "cmux-app__preview-tab"
                    }
                  >
                    {preview.label ?? preview.port ?? `Preview ${index + 1}`}
                  </button>
                ))}
              </div>
            ) : null}
            <iframe
              key={effectivePreview?.url ?? "preview"}
              src={effectivePreview?.url}
              title="cmux preview iframe"
              allow="clipboard-read; clipboard-write; fullscreen"
              sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
            />
          </>
        )}
      </section>
    </div>
  );
}

function AgentsList({ workspace }: { workspace: CmuxWorkspaceResult }) {
  if (!workspace.run.agents.length) {
    return null;
  }
  return (
    <ul className="cmux-app__agents">
      {workspace.run.agents.map((agent) => (
        <li key={`${agent.name}-${agent.status}`} className="cmux-app__agent">
          <span className={`cmux-app__agent-status cmux-app__agent-status--${agent.status}`}>
            {agent.status}
          </span>
          <span className="cmux-app__agent-name">{agent.name}</span>
          {agent.summary ? (
            <span className="cmux-app__agent-summary">{agent.summary}</span>
          ) : null}
        </li>
      ))}
    </ul>
  );
}

function CmuxWorkspaceApp() {
  const [workspace, setWorkspace] = useCmuxWorkspace();
  useWorkspacePolling(workspace, setWorkspace);

  useEffect(() => {
    if (!workspace) {
      return;
    }
    if (workspace.workspace.previews.length > 0) {
      void window.openai?.requestDisplayMode?.({ mode: "fullscreen" });
    }
  }, [workspace]);

  if (!workspace) {
    return (
      <div className="cmux-app__container">
        <p className="cmux-app__empty">Waiting for cmux tool output…</p>
      </div>
    );
  }

  return (
    <div className="cmux-app__container">
      <header className="cmux-app__header">
        <div>
          <p className="cmux-app__eyebrow">Task</p>
          <h1>{workspace.task.title}</h1>
          <p className="cmux-app__hint">
            {workspace.message ?? "Workspace provisioning"}
          </p>
        </div>
        <a
          href={workspace.task.url}
          target="_blank"
          rel="noreferrer noopener"
          className="cmux-app__link"
        >
          View in cmux
        </a>
      </header>
      <AgentsList workspace={workspace} />
      <WorkspaceIframes workspace={workspace} />
    </div>
  );
}

function injectStyles() {
  const existing = document.getElementById("cmux-app-styles");
  if (existing) {
    return;
  }
  const style = document.createElement("style");
  style.id = "cmux-app-styles";
  style.textContent = `
    :root {
      color-scheme: light dark;
    }
    .cmux-app__container {
      display: flex;
      flex-direction: column;
      gap: 1rem;
      padding: 1rem;
      font-family: Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: transparent;
      color: inherit;
    }
    .cmux-app__header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 1rem;
      flex-wrap: wrap;
    }
    .cmux-app__eyebrow {
      font-size: 0.75rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      opacity: 0.7;
      margin: 0 0 0.25rem;
    }
    .cmux-app__link {
      color: inherit;
      font-size: 0.875rem;
      text-decoration: underline;
      text-underline-offset: 4px;
    }
    .cmux-app__hint {
      font-size: 0.875rem;
      opacity: 0.7;
      margin-top: 0.25rem;
    }
    .cmux-app__grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 1rem;
    }
    .cmux-app__panel {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
      background: rgba(128, 128, 128, 0.08);
      border-radius: 0.75rem;
      padding: 0.75rem;
      backdrop-filter: blur(6px);
    }
    .cmux-app__panel-header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 0.5rem;
    }
    .cmux-app__panel-actions {
      display: flex;
      gap: 0.5rem;
      align-items: center;
    }
    .cmux-app__panel iframe {
      width: 100%;
      min-height: 360px;
      border: none;
      border-radius: 0.5rem;
      background: #0f172a;
    }
    .cmux-app__empty {
      padding: 1rem;
      border: 1px dashed rgba(128, 128, 128, 0.6);
      border-radius: 0.75rem;
      text-align: center;
      font-size: 0.875rem;
    }
    .cmux-app__agents {
      list-style: none;
      padding: 0;
      margin: 0;
      display: flex;
      flex-wrap: wrap;
      gap: 0.5rem;
    }
    .cmux-app__agent {
      display: inline-flex;
      gap: 0.5rem;
      align-items: center;
      padding: 0.35rem 0.6rem;
      border-radius: 999px;
      background: rgba(128, 128, 128, 0.12);
      font-size: 0.75rem;
    }
    .cmux-app__agent-status {
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .cmux-app__agent-status--pending { color: #facc15; }
    .cmux-app__agent-status--running { color: #34d399; }
    .cmux-app__agent-status--succeeded { color: #60a5fa; }
    .cmux-app__agent-status--failed { color: #f87171; }
    .cmux-app__agent-name {
      font-weight: 600;
    }
    .cmux-app__agent-summary {
      opacity: 0.7;
    }
    .cmux-app__preview-tabs {
      display: flex;
      gap: 0.5rem;
      flex-wrap: wrap;
    }
    .cmux-app__preview-tab {
      border: none;
      border-radius: 999px;
      background: rgba(128, 128, 128, 0.16);
      color: inherit;
      cursor: pointer;
      padding: 0.35rem 0.75rem;
      font-size: 0.75rem;
    }
    .cmux-app__preview-tab--active {
      background: rgba(96, 165, 250, 0.25);
    }
  `;
  document.head.appendChild(style);
}

function mount() {
  if (typeof document === "undefined") {
    return;
  }
  injectStyles();
  const mountId = "cmux-chatgpt-app-root";
  const existing = document.getElementById(mountId);
  const container = existing ?? (() => {
    const element = document.createElement("div");
    element.id = mountId;
    document.body.appendChild(element);
    return element;
  })();

  const root = createRoot(container);
  root.render(
    <StrictMode>
      <CmuxWorkspaceApp />
    </StrictMode>,
  );
}

mount();
