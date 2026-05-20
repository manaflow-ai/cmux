export type ProviderId = "codex" | "claude" | "opencode";

export type RendererKind = "react" | "solid";

export type ProviderInfo = {
  id: ProviderId;
  displayName: string;
  executableName: string;
  transportKind: "stdio-jsonl" | "http-loopback";
  arguments: string[];
};

export type AppContext = {
  panelId: string;
  workspaceId: string;
  renderer: RendererKind;
  initialProviderId: ProviderId;
  workingDirectory?: string;
  copy: AgentSessionCopy;
};

export type AgentSessionCopy = {
  start: string;
  stop: string;
  send: string;
  promptPlaceholder: string;
};

export type AgentEvent =
  | {
      type: "provider.started";
      sessionId: string;
      providerId: ProviderId;
      executablePath: string;
      arguments: string[];
    }
  | {
      type: "provider.output";
      sessionId: string;
      providerId: ProviderId;
      stream: "stdout" | "stderr";
      text: string;
    }
  | {
      type: "provider.exit";
      sessionId: string;
      providerId: ProviderId;
      status: number;
    };
