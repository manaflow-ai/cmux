export type OnboardingStep =
  | "welcome"
  | "connect-repo"
  | "explain-env-vars"
  | "collect-env-vars"
  | "security-assurance"
  | "creating-environment"
  | "complete";

export type MessageRole = "assistant" | "user" | "system";

export type MessageType = "text" | "action" | "input-request";

export interface OnboardingMessage {
  id: string;
  role: MessageRole;
  type: MessageType;
  content: string;
  timestamp: number;
  // For action messages
  actionType?: "repo-connected" | "env-vars-added" | "environment-created";
  // For input requests
  inputType?: "env-vars" | "confirmation";
}

export interface TerminalLine {
  id: string;
  content: string;
  type: "command" | "output" | "success" | "error" | "info";
  timestamp: number;
}

export interface OnboardingState {
  step: OnboardingStep;
  messages: OnboardingMessage[];
  terminalLines: TerminalLine[];
  repo: string | null;
  envVars: Array<{ name: string; value: string }>;
  isCreating: boolean;
  error: string | null;
}
