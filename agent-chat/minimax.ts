import type { AgentModelProviderCatalog } from "./catalog";

export const MINIMAX_DEFAULT_MODEL = "MiniMax-M3.1-Flash";
const MINIMAX_MODELS = [
  { value: MINIMAX_DEFAULT_MODEL, label: "MiniMax M3.1 Flash" },
  { value: "MiniMax-M3", label: "MiniMax M3" },
];

export function minimaxModels(remote?: AgentModelProviderCatalog) {
  return MINIMAX_MODELS.map((model) => ({
    ...model,
    description: remote?.models.find((entry) => entry.id === model.value)?.description,
  }));
}
