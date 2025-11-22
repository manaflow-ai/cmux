import type { EditorSettingsUpload } from "@cmux/shared/editor-settings";
import { maskSensitive, singleQuote } from "./shell";
import type { MorphInstance } from "./git";

interface ApplyParams {
  instance: MorphInstance;
  editorSettings: EditorSettingsUpload;
}

function encodeAuthFiles(authFiles: EditorSettingsUpload["authFiles"]): string {
  return Buffer.from(JSON.stringify(authFiles), "utf8").toString("base64");
}

async function writeAuthFiles(instance: MorphInstance, payloadB64: string) {
  const script = `
set -euo pipefail
export CMUX_EDITOR_FILES_B64=${singleQuote(payloadB64)}
python3 - <<'PYCODE'
import base64
import json
import os
import pathlib

payload = os.environ.get("CMUX_EDITOR_FILES_B64")
if not payload:
    raise SystemExit("Missing editor settings payload")

files = json.loads(base64.b64decode(payload))
home = os.environ.get("HOME", "/root")

for file in files:
    dest = file.get("destinationPath")
    content = file.get("contentBase64")
    if not dest or content is None:
        continue

    dest = dest.replace("$HOME", home)
    directory = os.path.dirname(dest)
    if directory:
        os.makedirs(directory, exist_ok=True)

    data = base64.b64decode(content)
    with open(dest, "wb") as handle:
        handle.write(data)

    mode = file.get("mode")
    if mode:
        os.chmod(dest, int(mode, 8))
PYCODE
`;

  const result = await instance.exec(`bash -lc ${singleQuote(script)}`);
  if (result.exit_code !== 0) {
    const stdout = maskSensitive(result.stdout || "");
    const stderr = maskSensitive(result.stderr || "");
    throw new Error(
      `[editor-settings] Failed to write auth files exit=${result.exit_code} stdout=${stdout.slice(
        0,
        200
      )} stderr=${stderr.slice(0, 200)}`
    );
  }
}

async function runStartupCommands(
  instance: MorphInstance,
  commands: string[]
) {
  if (commands.length === 0) {
    return;
  }

  const script = `
set -euo pipefail
${commands.join("\n")}
`;

  const result = await instance.exec(`bash -lc ${singleQuote(script)}`);
  if (result.exit_code !== 0) {
    const stdout = maskSensitive(result.stdout || "");
    const stderr = maskSensitive(result.stderr || "");
    throw new Error(
      `[editor-settings] Startup commands failed exit=${result.exit_code} stdout=${stdout.slice(
        0,
        200
      )} stderr=${stderr.slice(0, 200)}`
    );
  }
}

export async function applyEditorSettingsToInstance({
  instance,
  editorSettings,
}: ApplyParams): Promise<void> {
  if (editorSettings.authFiles.length > 0) {
    await writeAuthFiles(instance, encodeAuthFiles(editorSettings.authFiles));
  }
  if (editorSettings.startupCommands.length > 0) {
    await runStartupCommands(instance, editorSettings.startupCommands);
  }
}
