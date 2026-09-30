import { expect, test } from "bun:test";
import { PROVIDERS } from "../server";

test("Gemini ACP command uses the documented experimental flag", () => {
  const gemini = PROVIDERS.find((provider) => provider.id === "gemini");
  expect(gemini).toBeDefined();
  expect(gemini?.adapter).toBe("acp");
  expect(gemini?.cmd).toEqual(["gemini", "--experimental-acp"]);
});
