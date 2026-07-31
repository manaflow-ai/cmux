import { cp, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const temporary = await mkdtemp(join(tmpdir(), "cmux-surface-status-pi-test-"));
try {
  await cp(
    join(here, "../SurfaceStatusApp/AdapterPayloads/pi-sidebar-agent-status.txt"),
    join(temporary, "pi-sidebar-agent-status.ts")
  );
  await cp(join(here, "pi-sidebar-agent-status.test.ts"), join(temporary, "pi-sidebar-agent-status.test.ts"));
  const result = spawnSync(
    process.execPath,
    ["--experimental-strip-types", "--test", join(temporary, "pi-sidebar-agent-status.test.ts")],
    { stdio: "inherit" }
  );
  process.exitCode = result.status ?? 1;
} finally {
  await rm(temporary, { recursive: true, force: true });
}
