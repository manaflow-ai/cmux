import { app } from "@/lib/hono-app";
import { createClient } from "@hey-api/openapi-ts";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const quiet = !!process.env.CLAUDECODE;
const log = quiet ? () => {} : console.log.bind(console);

const startTime = performance.now();
const __dirname = path.dirname(fileURLToPath(import.meta.url));

const fetchStart = performance.now();
const doc = await app.request("/api/doc", {
  method: "GET",
});
log(`[${(performance.now() - fetchStart).toFixed(2)}ms] fetch /api/doc`);

const outputPath = path.join(
  __dirname,
  "../../../packages/www-openapi-client/src/client"
);
const tsConfigPath = path.join(
  __dirname,
  "../../../packages/www-openapi-client/tsconfig.json"
);

// write to tmp file (unique name to avoid concurrent collisions)
const tmpFile = path.join(
  os.tmpdir(),
  `openapi-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`
);
fs.writeFileSync(tmpFile, await doc.text());

const genStart = performance.now();
await createClient({
  input: tmpFile,
  output: {
    path: outputPath,
    tsConfigPath,
  },
  plugins: [
    "@hey-api/client-fetch",
    "@hey-api/typescript",
    "@tanstack/react-query",
  ],
  logs: quiet ? { level: "silent" } : undefined,
});
log(`[${(performance.now() - genStart).toFixed(2)}ms] generate client`);

// Post-process: Remove .js extensions from imports for Turbopack compatibility
// The generated files use ESM-style .js extensions, but Turbopack in Next.js
// doesn't properly resolve these when importing from a workspace TypeScript package
const postStart = performance.now();
const removeJsExtensions = (dir: string) => {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      removeJsExtensions(fullPath);
    } else if (entry.name.endsWith(".ts")) {
      const content = fs.readFileSync(fullPath, "utf-8");
      // Replace .js extensions in import/export from statements
      const updated = content.replace(
        /from\s+(['"])(.+?)\.js\1/g,
        "from $1$2$1"
      );
      if (content !== updated) {
        fs.writeFileSync(fullPath, updated);
      }
    }
  }
};
removeJsExtensions(outputPath);
log(`[${(performance.now() - postStart).toFixed(2)}ms] post-process imports`);

try {
  fs.unlinkSync(tmpFile);
} catch {
  // ignore if already removed by concurrent runs
}

log(`[${(performance.now() - startTime).toFixed(2)}ms] watch-openapi complete`);
console.log("[watch-openapi] initial client generation complete");
