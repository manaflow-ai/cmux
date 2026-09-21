import { harnessRecommendations } from "../server";
import type { ProviderDef } from "../types";

function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message);
}

const providers: ProviderDef[] = [
  { id: "zeta", label: "Zeta", adapter: "acp", cmd: ["zeta"], installCommand: "install-zeta" },
  { id: "alpha", label: "Alpha", adapter: "acp", cmd: ["alpha"] },
];
const recommendations = harnessRecommendations(
  providers,
  (provider) => provider.id === "zeta",
  (provider) => provider.id === "zeta" ? ["/", "$"] : ["@"],
);

assert(recommendations.length === 2, "one recommendation should be emitted per harness");
assert(recommendations[0]?.id === "zeta", "installed harnesses should be prioritized");
assert(recommendations[0]?.reason === "Installed and ready", "installed harness should explain readiness");
assert(recommendations[0]?.triggers.join("") === "/$", "command triggers should be exposed for palette consumers");
assert(recommendations[1]?.reason === "Harness is not installed", "missing install metadata should remain actionable");
assert(recommendations[1]?.installCommand === undefined, "missing install metadata should not invent a command");
