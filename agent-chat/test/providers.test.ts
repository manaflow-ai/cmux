import { expect, test } from "bun:test";
import { providerDefinitionsForTest } from "../server";

test("registers Cursor Agent as an ACP provider", () => {
  const cursor = providerDefinitionsForTest().find((provider) => provider.id === "cursor-agent");
  expect(cursor).toEqual({
    id: "cursor-agent",
    label: "Cursor Agent",
    adapter: "acp",
    cmd: ["cursor-agent", "acp"],
    installCommand: "curl https://cursor.com/install -fsS | bash",
  });
});
