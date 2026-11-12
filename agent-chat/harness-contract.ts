// Shared transport contract. Display text is resolved by the client locale.
export type HarnessMessageId = "foundPath" | "foundCommand" | "installed" | "missing" | "install" | "benefitPi" | "benefitOpenagent" | "benefitClaude" | "benefitSuperpowers";
export interface HarnessMessage { id: HarnessMessageId; params?: Record<string, string>; }
export interface HarnessRecommendation {
  id: string;
  label: string;
  installed: boolean;
  priority: number;
  triggers: string[];
  reason: HarnessMessage;
  kind: "provider" | "workflow";
  provider?: string;
  benefit?: HarnessMessage;
  tags?: string[];
  evidence?: HarnessMessage;
  installCommand?: string;
}
export type HarnessMessages = Record<HarnessMessageId | "title" | "selectionNotice" | "selectProvider", string>;
export type HarnessCatalogs = Record<string, HarnessMessages>;
