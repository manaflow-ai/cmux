import { expect, test } from "bun:test";
import { commandForSession } from "../adapters/acp";
import { providerDefinitionsForTest } from "../server";

test("registers Goose as an ACP provider", () => {
  const goose = providerDefinitionsForTest().find((provider) => provider.id === "goose");
  expect(goose).toBeDefined();
  expect(goose).toMatchObject({
    id: "goose",
    label: "Goose",
    adapter: "acp",
    cmd: ["goose", "acp"],
    installCommand: "curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | bash",
  });
  expect(commandForSession(goose!, {})).toEqual(["goose", "acp"]);
});
