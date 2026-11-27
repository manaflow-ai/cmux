import { expect, test } from "bun:test";
import { commandForSession } from "../adapters/acp";
import { providerDefinitionsForTest } from "../server";

const providers = providerDefinitionsForTest();

test("Gemini ACP command uses the documented experimental flag", () => {
  const gemini = providers.find((provider) => provider.id === "gemini");
  expect(gemini).toBeDefined();
  expect(gemini?.adapter).toBe("acp");
  expect(gemini?.cmd).toEqual(["gemini", "--experimental-acp"]);

  const expectedCommand = [...(gemini?.cmd ?? [])];
  if (gemini?.models?.length) {
    expectedCommand.push("--model", gemini.defaultModel ?? gemini.models[0]!.value);
  }
  expect(commandForSession(gemini!, {})).toEqual(expectedCommand);
});

test("registers Cursor Agent as an ACP provider", () => {
  const cursor = providers.find((provider) => provider.id === "cursor-agent");
  expect(cursor).toBeDefined();
  expect(cursor).toMatchObject({
    id: "cursor-agent",
    label: "Cursor Agent",
    adapter: "acp",
    cmd: ["cursor-agent", "acp"],
    installCommand: "curl https://cursor.com/install -fsS | bash",
  });
  expect(commandForSession(cursor!, {})).toEqual(["cursor-agent", "acp"]);
});

test("appends the selected model to ACP provider commands", () => {
  expect(commandForSession({ id: "fake", label: "Fake", adapter: "acp", cmd: ["fake-agent"], models: [{ value: "model-a", label: "Model A" }] }, {})).toEqual([
    "fake-agent",
    "--model",
    "model-a",
  ]);
});
