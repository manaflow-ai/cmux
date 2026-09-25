import assert from "node:assert/strict";
import {
  AGENT_CHAT_LOCALES,
  agentChatCopyForLocale,
  agentChatText,
  resolveAgentChatLocale,
  type AgentChatTextKey,
} from "../src/i18n";

const canonicalLocales = [
  "en", "ja", "zh-CN", "zh-TW", "ko", "de", "es", "fr", "it", "da",
  "pl", "ru", "bs", "ar", "no", "pt-BR", "th", "tr", "km", "uk",
];

assert.deepEqual([...AGENT_CHAT_LOCALES], canonicalLocales);

const keys: AgentChatTextKey[] = [
  "continuedNewChat",
  "movedServingRoute",
  "continueNewChat",
  "continueElsewhere",
];
const english = agentChatCopyForLocale("en");

for (const locale of AGENT_CHAT_LOCALES) {
  const copy = agentChatCopyForLocale(locale);
  for (const key of keys) {
    assert(copy[key].trim().length > 0, `${locale} is missing ${key}`);
    if (locale !== "en") {
      assert.notEqual(copy[key], english[key], `${locale} copied English for ${key}`);
    }
  }
}

assert.equal(resolveAgentChatLocale(["zh-Hant-HK"]), "zh-TW");
assert.equal(resolveAgentChatLocale(["zh-Hans-SG"]), "zh-CN");
assert.equal(resolveAgentChatLocale(["pt-PT"]), "pt-BR");
assert.equal(resolveAgentChatLocale(["nb-NO"]), "no");
assert.equal(resolveAgentChatLocale(["fr-CA"]), "fr");
assert.equal(resolveAgentChatLocale(["xx-YY"]), "en");
assert.equal(agentChatText("continueElsewhere", ["de-DE"]), "Anderswo fortfahren");

console.log("agent-chat i18n tests passed");
