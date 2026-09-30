import { expect, test } from "bun:test";
import { PROVIDERS } from "../server";

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
