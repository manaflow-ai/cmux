export type ProviderId = "codex" | "claude" | "opencode";

export type RendererKind = "react" | "solid";

export type ProviderInfo = {
  id: ProviderId;
  displayName: string;
  executableName: string;
  transportKind: "stdio-jsonrpc" | "stdio-jsonl" | "http-loopback";
  arguments: string[];
  autoStart: boolean;
};

export type AgentSessionTheme = {
  isDark: boolean;
  pageBackground: string;
  surfaceBackground: string;
  surfaceElevatedBackground: string;
  inputBackground: string;
  border: string;
  borderStrong: string;
  text: string;
  mutedText: string;
  softText: string;
  accent: string;
  accentSoft: string;
  danger: string;
  shadow: string;
};

export type AppContext = {
  panelId: string;
  workspaceId: string;
  renderer: RendererKind;
  initialProviderId: ProviderId;
  workingDirectory?: string;
  copy: AgentSessionCopy;
  theme: AgentSessionTheme;
};

export type AgentSessionCopy = {
  start: string;
  stop: string;
  send: string;
  provider: string;
  rateLimits: string;
  voiceInput: string;
  promptPlaceholder: string;
  loadingStatus: string;
  idleStatus: string;
  startingStatus: string;
  runningStatus: string;
  stoppingStatus: string;
  failedStatus: string;
  rendererReadyFormat: string;
  stopped: string;
  sentCharsFormat: string;
  providerStarted: string;
  providerExitedFormat: string;
  requestFailed: string;
};

export type AgentEvent =
  | {
      type: "app.theme";
      theme: AgentSessionTheme;
    }
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
