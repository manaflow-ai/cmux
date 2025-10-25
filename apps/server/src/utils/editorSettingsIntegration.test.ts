import { describe, expect, it } from "vitest";
import { promises as fs } from "node:fs";
import path from "node:path";
import os from "node:os";
import { collectPreferredEditorSettingsFiles } from "./editorSettingsIntegration";

async function createTempHome(prefix: string): Promise<string> {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), prefix));
  return base;
}

describe("collectPreferredEditorSettingsFiles", () => {
  it("selects the most recently modified editor settings", async () => {
    const homeDir = await createTempHome("cmux-editor-settings-");
    try {
      const vscodeUserDir = path.join(homeDir, ".config", "Code", "User");
      await fs.mkdir(vscodeUserDir, { recursive: true });
      const vscodeSettingsPath = path.join(vscodeUserDir, "settings.json");
      await fs.writeFile(vscodeSettingsPath, JSON.stringify({ theme: "Dark" }));
      await fs.utimes(vscodeSettingsPath, new Date(Date.now() - 20_000), new Date(Date.now() - 20_000));

      const cursorUserDir = path.join(homeDir, ".config", "Cursor", "User");
      await fs.mkdir(cursorUserDir, { recursive: true });
      const cursorSettingsPath = path.join(cursorUserDir, "settings.json");
      await fs.writeFile(cursorSettingsPath, JSON.stringify({ theme: "Light" }));
      const cursorKeybindingsPath = path.join(cursorUserDir, "keybindings.json");
      await fs.writeFile(cursorKeybindingsPath, JSON.stringify([{ key: "ctrl+k" }]));
      const snippetDir = path.join(cursorUserDir, "snippets");
      await fs.mkdir(snippetDir, { recursive: true });
      const snippetPath = path.join(snippetDir, "sample.json");
      await fs.writeFile(snippetPath, JSON.stringify({ "Print Hello": "console.log('hi')" }));

      const result = await collectPreferredEditorSettingsFiles({
        homeDir,
        platform: "linux",
      });

      expect(result.editorId).toBe("cursor");
      expect(result.files.length).toBeGreaterThan(0);

      const userSettingsFile = result.files.find((file) =>
        file.destinationPath.endsWith("/User/settings.json")
      );
      expect(userSettingsFile).toBeDefined();
      const decodedSettings = Buffer.from(
        userSettingsFile!.contentBase64,
        "base64"
      ).toString("utf8");
      expect(decodedSettings).toContain("Light");

      const snippetFile = result.files.find((file) =>
        file.destinationPath.includes("snippets/sample.json")
      );
      expect(snippetFile).toBeDefined();
    } finally {
      await fs.rm(homeDir, { recursive: true, force: true });
    }
  });

  it("returns no files when no editor settings exist", async () => {
    const homeDir = await createTempHome("cmux-editor-settings-empty-");
    try {
      const result = await collectPreferredEditorSettingsFiles({
        homeDir,
        platform: "linux",
      });
      expect(result.editorId).toBeUndefined();
      expect(result.files).toHaveLength(0);
    } finally {
      await fs.rm(homeDir, { recursive: true, force: true });
    }
  });
});
