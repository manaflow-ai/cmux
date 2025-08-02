import { promises as fs } from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";

export async function generateExtensionInstallScript(
  vscodeSettingsDir: string
): Promise<string | null> {
  const extensionsPath = path.join(vscodeSettingsDir, "extensions.txt");
  
  try {
    const extensionsContent = await fs.readFile(extensionsPath, "utf-8");
    const extensions = extensionsContent
      .split("\n")
      .filter(ext => ext.trim().length > 0)
      .map(ext => {
        // Extract publisher.name from folder names like "ms-python.python-2024.14.1"
        const match = ext.match(/^([^.]+\.[^-]+)/);
        return match ? match[1] : null;
      })
      .filter(Boolean);

    if (extensions.length === 0) {
      return null;
    }

    // Generate a script that installs extensions
    const script = `#!/bin/bash
echo "Installing VS Code extensions..."
for ext in ${extensions.join(" ")}; do
  echo "Installing $ext..."
  code-server --install-extension "$ext" --force 2>/dev/null || true
done
echo "Extensions installation complete."
`;

    return script;
  } catch (error) {
    return null;
  }
}

export async function createExtensionInstallScript(
  vscodeSettingsDir: string,
  targetPath: string
): Promise<boolean> {
  const script = await generateExtensionInstallScript(vscodeSettingsDir);
  
  if (!script) {
    return false;
  }

  try {
    await fs.writeFile(targetPath, script, { mode: 0o755 });
    return true;
  } catch (error) {
    console.error("Failed to write extension install script:", error);
    return false;
  }
}