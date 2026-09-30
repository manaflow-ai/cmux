import { expect, test } from "bun:test";
import { PROVIDERS } from "../server";
import * as acp from "../adapters/acp";

test("Gemini ACP command uses the documented experimental flag", () => {
  const gemini = PROVIDERS.find((provider) => provider.id === "gemini");
  expect(gemini).toBeDefined();
  expect(gemini?.adapter).toBe("acp");
  expect(gemini?.cmd).toEqual(["gemini", "--experimental-acp"]);
});

test("registers Cursor Agent as an ACP provider", () => {
  const cursor = PROVIDERS.find((provider) => provider.id === "cursor-agent");
  expect(cursor).toEqual({
    id: "cursor-agent",
    label: "Cursor Agent",
    adapter: "acp",
    cmd: ["cursor-agent", "acp"],
    installCommand: "curl https://cursor.com/install -fsS | bash",
  });
});

test("appends the selected model to ACP provider commands", () => {
  const commandForSession = (acp as any).commandForSession as ((def: any, options: Record<string, string>) => string[]);
  expect(commandForSession).toBeDefined();
  expect(commandForSession({ cmd: ["fake-agent"], models: [{ value: "model-a", label: "Model A" }] }, {})).toEqual([
    "fake-agent",
    "--model",
    "model-a",
  ]);
});
